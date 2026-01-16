data "google_secret_manager_secret_version" "argocd_app_pem_key" {
  secret = "argocd-gh-app-pem-key"
}


resource "helm_release" "argocd" {
  depends_on = [module.talos]
  name       = "argocd"

  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  version    = "7.7.11"

  create_namespace = true
}

resource "kubernetes_secret_v1" "argocd_repo_access" {
  depends_on = [module.talos, helm_release.argocd]
  metadata {
    name = "argo-private-repo-secret"

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
