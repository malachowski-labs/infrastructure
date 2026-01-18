provider "hcloud" {
  token = var.hcloud_token
}

provider "google" {
    project = "malachowski"
}

provider "cloudflare" {
  api_token = var.cloudflare_token
}

provider "kubernetes" {
  host = module.talos.kubeconfig_data.host
  client_certificate = module.talos.kubeconfig_data.client_certificate
  client_key = module.talos.kubeconfig_data.client_key
  cluster_ca_certificate = module.talos.kubeconfig_data.cluster_ca_certificate
}

provider "helm" {
  kubernetes = {
    host = module.talos.kubeconfig_data.host
    client_certificate = module.talos.kubeconfig_data.client_certificate
    client_key = module.talos.kubeconfig_data.client_key
    cluster_ca_certificate = module.talos.kubeconfig_data.cluster_ca_certificate
  }
}

data "kubernetes_secret_v1" "argo_cluser_password" {
  depends_on = [ helm_release.argocd  ]

  metadata {
    name      = "argocd-initial-admin-secret"
    namespace = "argocd"
  }
}

provider "argocd" {
  port_forward_with_namespace = "argocd"
  username = "admin"
  password = data.kubernetes_secret_v1.argo_cluser_password.data["password"]

  kubernetes {
    host = module.talos.kubeconfig_data.host
    client_certificate = module.talos.kubeconfig_data.client_certificate
    client_key = module.talos.kubeconfig_data.client_key
    cluster_ca_certificate = module.talos.kubeconfig_data.cluster_ca_certificate
  }
}


