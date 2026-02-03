locals {
  eso_namespace      = "external-secrets"
  eso_sa_name        = "external-secrets-operator"
  cluster_issuer_url = "https://oidc.malachowski.me"
}

# =====================================
# GCP Service Account for ESO
# =====================================

resource "google_service_account" "external_secrets" {
  account_id   = "external-secrets-operator"
  display_name = "External Secrets Operator Service Account"
  description  = "Service Account used by External Secrets Operator via Workload Identity Federation"
}

# Grant Secret Manager access
resource "google_project_iam_member" "external_secrets_secret_accessor" {
  project = "malachowski"
  role    = "roles/secretmanager.secretAccessor"
  member  = "serviceAccount:${google_service_account.external_secrets.email}"
}

# =====================================
# Workload Identity Pool & Provider
# =====================================

resource "google_iam_workload_identity_pool" "kubernetes" {
  workload_identity_pool_id = "kubernetes-pool"
  display_name              = "Kubernetes Workload Identity"
  description               = "Workload Identity Pool for Kubernetes cluster"
  disabled                  = false
}

resource "google_iam_workload_identity_pool_provider" "kubernetes_oidc" {
  workload_identity_pool_id          = google_iam_workload_identity_pool.kubernetes.workload_identity_pool_id
  workload_identity_pool_provider_id = "kubernetes-oidc-provider"
  display_name                       = "Kubernetes OIDC Provider"
  description                        = "OIDC provider for Kubernetes service accounts"
  disabled                           = false

  attribute_mapping = {
    "google.subject"                 = "assertion.sub"
    "attribute.kubernetes_namespace" = "assertion['kubernetes.io'].namespace"
    "attribute.kubernetes_pod"       = "assertion['kubernetes.io'].pod.name"
    "attribute.kubernetes_sa"        = "assertion['kubernetes.io'].serviceaccount.name"
  }

  attribute_condition = "assertion.sub.startsWith('system:serviceaccount:${local.eso_namespace}:')"

  oidc {
    issuer_uri = local.cluster_issuer_url
  }
}

# =====================================
# IAM Binding for Workload Identity
# =====================================

resource "google_service_account_iam_member" "workload_identity_binding" {
  service_account_id = google_service_account.external_secrets.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.kubernetes.name}/attribute.kubernetes_sa/${local.eso_sa_name}"
}

# =====================================
# OIDC Discovery Service
# =====================================

# Namespace for OIDC discovery service
resource "kubernetes_namespace_v1" "oidc_discovery" {
  depends_on = [module.talos]

  metadata {
    name = "oidc-discovery"

    labels = {
      name = "oidc-discovery"
    }
  }
}

# ConfigMap with OIDC discovery configuration
resource "kubernetes_config_map_v1" "oidc_discovery" {
  depends_on = [kubernetes_namespace_v1.oidc_discovery]

  metadata {
    name      = "oidc-discovery"
    namespace = kubernetes_namespace_v1.oidc_discovery.metadata[0].name
  }

  data = {
    "openid-configuration" = jsonencode({
      issuer                                = local.cluster_issuer_url
      jwks_uri                              = "${local.cluster_issuer_url}/openid/v1/jwks"
      response_types_supported              = ["id_token"]
      subject_types_supported               = ["public"]
      id_token_signing_alg_values_supported = ["RS256"]
    })
  }
}

# Deployment for OIDC discovery service
resource "kubernetes_deployment_v1" "oidc_discovery" {
  depends_on = [
    kubernetes_namespace_v1.oidc_discovery,
    kubernetes_config_map_v1.oidc_discovery,
    module.talos
  ]

  metadata {
    name      = "oidc-discovery"
    namespace = kubernetes_namespace_v1.oidc_discovery.metadata[0].name

    labels = {
      app = "oidc-discovery"
    }
  }

  spec {
    replicas = 2

    selector {
      match_labels = {
        app = "oidc-discovery"
      }
    }

    template {
      metadata {
        labels = {
          app = "oidc-discovery"
        }
      }

      spec {
        container {
          name  = "nginx"
          image = "nginx:alpine"

          port {
            container_port = 80
            name           = "http"
          }

          volume_mount {
            name       = "oidc-config"
            mount_path = "/usr/share/nginx/html/.well-known"
            read_only  = true
          }

          # Add a simple nginx config to proxy the JWKS endpoint to the API server
          volume_mount {
            name       = "nginx-config"
            mount_path = "/etc/nginx/conf.d"
            read_only  = true
          }

          liveness_probe {
            http_get {
              path = "/.well-known/openid-configuration"
              port = 80
            }
            initial_delay_seconds = 5
            period_seconds        = 10
          }

          readiness_probe {
            http_get {
              path = "/.well-known/openid-configuration"
              port = 80
            }
            initial_delay_seconds = 5
            period_seconds        = 5
          }

          resources {
            requests = {
              cpu    = "10m"
              memory = "32Mi"
            }
            limits = {
              cpu    = "50m"
              memory = "64Mi"
            }
          }
        }

        volume {
          name = "oidc-config"
          config_map {
            name = kubernetes_config_map_v1.oidc_discovery.metadata[0].name
          }
        }

        volume {
          name = "nginx-config"
          config_map {
            name = kubernetes_config_map_v1.oidc_nginx_config.metadata[0].name
          }
        }
      }
    }
  }
}

# Nginx config to proxy JWKS from API server
resource "kubernetes_config_map_v1" "oidc_nginx_config" {
  depends_on = [kubernetes_namespace_v1.oidc_discovery, module.talos]

  metadata {
    name      = "oidc-nginx-config"
    namespace = kubernetes_namespace_v1.oidc_discovery.metadata[0].name
  }

  data = {
    "default.conf" = <<-EOT
      server {
          listen 80;
          server_name _;

          location /.well-known/openid-configuration {
              alias /usr/share/nginx/html/.well-known/openid-configuration;
              add_header Content-Type application/json;
              add_header Access-Control-Allow-Origin *;
          }

          location /openid/v1/jwks {
              proxy_pass https://kubernetes.default.svc.cluster.local/openid/v1/jwks;
              proxy_ssl_verify off;
              proxy_set_header Host $host;
              proxy_set_header X-Real-IP $remote_addr;
              add_header Access-Control-Allow-Origin *;
          }

          location / {
              return 404;
          }
      }
    EOT
  }
}

# Service for OIDC discovery
resource "kubernetes_service_v1" "oidc_discovery" {
  depends_on = [kubernetes_deployment_v1.oidc_discovery, module.talos]

  metadata {
    name      = "oidc-discovery"
    namespace = kubernetes_namespace_v1.oidc_discovery.metadata[0].name

    labels = {
      app = "oidc-discovery"
    }
  }

  spec {
    type = "ClusterIP"

    selector = {
      app = "oidc-discovery"
    }

    port {
      name        = "http"
      port        = 80
      target_port = 80
      protocol    = "TCP"
    }
  }
}

# Ingress for OIDC discovery (exposed publicly)
resource "kubernetes_ingress_v1" "oidc_discovery" {
  depends_on = [kubernetes_service_v1.oidc_discovery, module.talos]

  metadata {
    name      = "oidc-discovery"
    namespace = kubernetes_namespace_v1.oidc_discovery.metadata[0].name

    annotations = {
      "cert-manager.io/cluster-issuer" = "letsencrypt-prod"
    }
  }

  spec {
    ingress_class_name = "traefik"

    tls {
      hosts = [
        "oidc.malachowski.me"
      ]
      secret_name = "oidc-discovery-tls"
    }

    rule {
      host = "oidc.malachowski.me"

      http {
        path {
          path      = "/"
          path_type = "Prefix"

          backend {
            service {
              name = kubernetes_service_v1.oidc_discovery.metadata[0].name
              port {
                number = 80
              }
            }
          }
        }
      }
    }
  }
}

# =====================================
# External Secrets Operator Resources
# =====================================

resource "kubernetes_namespace_v1" "external_secrets" {
  depends_on = [module.talos]

  metadata {
    name = local.eso_namespace

    labels = {
      name = local.eso_namespace
    }
  }
}

resource "kubernetes_service_account_v1" "external_secrets" {
  depends_on = [kubernetes_namespace_v1.external_secrets, module.talos]

  metadata {
    name      = local.eso_sa_name
    namespace = local.eso_namespace

    annotations = {
      "iam.gke.io/gcp-service-account" = google_service_account.external_secrets.email
    }
  }
}

# =====================================
# Helm Release for External Secrets Operator
# =====================================

resource "helm_release" "external_secrets" {
  depends_on = [
    kubernetes_namespace_v1.external_secrets,
    kubernetes_service_account_v1.external_secrets,
    module.talos
  ]

  name       = "external-secrets"
  namespace  = local.eso_namespace
  repository = "https://charts.external-secrets.io"
  chart      = "external-secrets"
  version    = "1.3.1"

  values = [
    yamlencode({
      serviceAccount = {
        create = false
        name   = kubernetes_service_account_v1.external_secrets.metadata[0].name
      }
      installCRDs = true
    })
  ]
}

# =====================================
# Secret Store Configuration
# =====================================

resource "kubectl_manifest" "secret_store_gcp" {
  depends_on = [helm_release.external_secrets, module.talos]

  yaml_body = yamlencode({
    apiVersion = "external-secrets.io/v1beta1"
    kind       = "ClusterSecretStore"
    metadata = {
      name = "gcpsm-secret-store"
    }
    spec = {
      provider = {
        gcpsm = {
          projectID = "malachowski"
          auth = {
            workloadIdentity = {
              clusterLocation = "eu"
              clusterName     = "prod.malachowski.me"
              serviceAccountRef = {
                name      = kubernetes_service_account_v1.external_secrets.metadata[0].name
                namespace = local.eso_namespace
              }
            }
          }
        }
      }
    }
  })
}
