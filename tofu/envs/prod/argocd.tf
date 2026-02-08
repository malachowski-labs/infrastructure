locals {
  github_argocd_oauth = jsondecode(data.google_secret_manager_secret_version.argocd_github_oauth_config.secret_data)

  github_argocd_client_id     = local.github_argocd_oauth.client_id
  github_argocd_client_secret = local.github_argocd_oauth.client_secret

  argocd_base_url = "https://argocd.malachowski.me"
  argocd_host     = replace(local.argocd_base_url, "https://", "")
}

data "google_secret_manager_secret_version" "argocd_app_pem_key" {
  secret = "argocd-gh-app-pem-key"
}

resource "kubernetes_namespace_v1" "argocd" {
  depends_on = [module.talos]

  metadata {
    name = "argocd"

    labels = {
      name                                 = "argocd"
      "pod-security.kubernetes.io/enforce" = "privileged"
    }
  }
}

data "google_secret_manager_secret_version" "argocd_github_oauth_config" {
  secret = var.argocd_github_oauth_app_secret_name
}

resource "helm_release" "argocd" {
  depends_on = [module.talos, kubernetes_namespace_v1.argocd]
  name       = "argocd"
  namespace  = kubernetes_namespace_v1.argocd.metadata[0].name

  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  version    = "7.7.11"

  create_namespace = true

  values = [
    yamlencode({
      configs = {
        cm = {
          url = local.argocd_base_url

          "dex.config"              = <<-EOT
          connectors:
          - type: github
            id: github
            name: GitHub
            config:
              clientID: $dex.github.clientID
              clientSecret: $dex.github.clientSecret
              orgs:
              - name: malachowski-labs
          EOT
          "users.anonymous.enabled" = false
          "admin.enabled"           = false

          "resource.compareoptions" = <<-EOT
          ignoreAggregateRoles: true
          ignoreResourceStatusField: all
          EOT

          "resource.customizations.ignoreDifferences.apps_StatefulSet" = <<-EOT
          jsonPointers:
            - /status
          EOT
        }


        params = {
          "server.insecure" = true
        }

        secret = {
          createSecret = true
          extra = {
            "dex.github.clientID"     = local.github_argocd_client_id
            "dex.github.clientSecret" = local.github_argocd_client_secret
          }
        }

        rbac = {
          "policy.default" = "role:readonly"
          "policy.csv"     = <<-EOT
            g, malachowski-labs:platform-team, role:admin
            g, role:admin, role:readonly
          EOT
        }
      }

      server = {
        service = {
          type = "ClusterIP"
        }

        ingress = {
          enabled          = true
          ingressClassName = "traefik"
          hostname         = local.argocd_host
          path             = "/"
          pathType         = "Prefix"
          annotations = {
            "traefik.ingress.kubernetes.io/router.entrypoints"    = "websecure"
            "traefik.ingress.kubernetes.io/router.tls"            = "true"
            "traefik.ingress.kubernetes.io/service.serversscheme" = "h2c"
          }
          tls = true
        }
      }
    })
  ]
}

resource "kubernetes_secret_v1" "argocd_repo_access" {
  depends_on = [module.talos, helm_release.argocd, kubernetes_namespace_v1.argocd]
  metadata {
    name      = "argo-private-repo-secret"
    namespace = kubernetes_namespace_v1.argocd.metadata[0].name

    labels = {
      "argocd.argoproj.io/secret-type" = "repo-creds"
    }
  }

  data = {
    type = "git"
    url  = "https://github.com/malachowski-labs"
    githubAppID : "2671629"
    githubAppInstallationID : "104588868"
    githubAppPrivateKey : data.google_secret_manager_secret_version.argocd_app_pem_key.secret_data
  }
}

resource "kubectl_manifest" "cluster_config" {
  depends_on = [kubernetes_secret_v1.argocd_repo_access, helm_release.argocd, kubernetes_namespace_v1.argocd]

  yaml_body = yamlencode({
    apiVersion = "argoproj.io/v1alpha1"
    kind       = "Application"
    metadata = {
      name      = "cluster-config"
      namespace = kubernetes_namespace_v1.argocd.metadata[0].name
    }

    spec = {
      project = "default"

      destination = {
        server = "https://kubernetes.default.svc"
      }

      source = {
        repoURL        = "https://github.com/malachowski-labs/manifests"
        path           = "clusters/prod.malachowski.me"
        targetRevision = "HEAD"

        directory = {
          recurse = true
        }
      }

      syncPolicy = {
        automated = {
          prune    = true
          selfHeal = true
        }

        syncOptions = [
          "ServerSideApply=true",
          "CreateNamespace=true"
        ]
      }
    }
  })
}

resource "kubectl_manifest" "traefik" {
  depends_on = [helm_release.argocd, kubernetes_namespace_v1.argocd, hcloud_load_balancer.this]

  yaml_body = yamlencode({
    apiVersion = "argoproj.io/v1alpha1"
    kind       = "Application"

    metadata = {
      name      = "traefik"
      namespace = kubernetes_namespace_v1.argocd.metadata[0].name
    }

    spec = {
      project = "default"

      destination = {
        server = "https://kubernetes.default.svc"
      }

      source = {
        repoURL        = "https://github.com/traefik/traefik-helm-chart.git"
        path           = "traefik"
        targetRevision = "v38.0.2"

        helm = {
          values = <<EOT
            logs:
              general:
                format: json
                level: INFO
              access:
                format: json
                enabled: true
                fields:
                  general:
                    defaultmode: keep
                  headers:
                    defaultmode: keep
            metrics:
              prometheus:
                serviceMonitor:
                  enabled: true
                  additionalLabels:
                    release: kube-prometheus-stack
                prometheusRule:
                  enabled: true
            service:
              annotations:
                load-balancer.hetzner.cloud/location: ${hcloud_load_balancer.this.location}
                load-balancer.hetzner.cloud/name: ${hcloud_load_balancer.this.name}
          EOT
        }
      }

      syncPolicy = {
        automated = {
          prune    = true
          selfHeal = true
        }

        syncOptions = [
          "CreateNamespace=true"
        ]
      }
    }
  })
}

