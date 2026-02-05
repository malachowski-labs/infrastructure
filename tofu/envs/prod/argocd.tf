data "google_secret_manager_secret_version" "argocd_app_pem_key" {
  secret = "argocd-gh-app-pem-key"
}

resource "kubernetes_namespace_v1" "argocd" {
  depends_on = [module.talos, hcloud_load_balancer_service.this]

  metadata {
    name = "argocd"

    labels = {
      name                                 = "argocd"
      "pod-security.kubernetes.io/enforce" = "privileged"
    }
  }
}

resource "helm_release" "argocd" {
  depends_on = [module.talos, kubernetes_namespace_v1.argocd, hcloud_load_balancer_service.this]
  name       = "argocd"
  namespace  = kubernetes_namespace_v1.argocd.metadata[0].name

  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  version    = "9.4.1"

  create_namespace = true
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

resource "argocd_application" "cluster_config" {
  depends_on = [kubernetes_secret_v1.argocd_repo_access, helm_release.argocd, kubernetes_namespace_v1.argocd]

  metadata {
    name      = "cluster-config"
    namespace = kubernetes_namespace_v1.argocd.metadata[0].name
  }

  wait = false

  spec {
    destination {
      server = "https://kubernetes.default.svc"
    }

    source {
      repo_url        = "https://github.com/malachowski-labs/manifests"
      path            = "clusters/prod.malachowski.me"
      target_revision = "HEAD"

      directory {
        recurse = true
      }
    }

    sync_policy {
      automated {
        prune     = true
        self_heal = true
      }

      sync_options = [
        "ServerSideApply=true",
        "CreateNamespace=true"
      ]
    }
  }
}

resource "argocd_application" "traefik" {
  depends_on = [helm_release.argocd, kubernetes_namespace_v1.argocd, hcloud_load_balancer.this]

  metadata {
    name      = "argo-traefik-chart"
    namespace = kubernetes_namespace_v1.argocd.metadata[0].name
  }

  wait = true

  spec {
    destination {
      server = "https://kubernetes.default.svc"
    }

    source {
      repo_url        = "https://github.com/traefik/traefik-helm-chart.git"
      path            = "traefik"
      target_revision = "v38.0.2"

      helm {
        values = <<EOT
          logs:
            general:
              level: INFO
            access:
              enabled: true
          service:
            annotations:
              load-balancer.hetzner.cloud/location: ${hcloud_load_balancer.this.location}
              load-balancer.hetzner.cloud/name: ${hcloud_load_balancer.this.name}
        EOT
      }
    }

    sync_policy {
      automated {
        prune     = true
        self_heal = true
      }

      sync_options = [
        "CreateNamespace=true"
      ]
    }
  }
}

