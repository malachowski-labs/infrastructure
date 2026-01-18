terraform {
  required_version = ">= 1.8.0"

  required_providers {
    google = {
      source = "hashicorp/google"
      version = ">= 3.5.0"
    }

    argocd = {
      source = "argoproj-labs/argocd"
      version = ">= 7.12.5"
    }

    kubernetes = {
      source = "hashicorp/kubernetes"
      version = ">= 2.35.1"
    }

    cloudflare = {
      source = "cloudflare/cloudflare"
      version = ">= 4.0"
    }

    helm = {
      source = "hashicorp/helm"
      version = ">= 2.7.1"
    }

    hcloud = {
      source = "hetznercloud/hcloud"
      version = ">= 1.37.3"
    }
  }
}
