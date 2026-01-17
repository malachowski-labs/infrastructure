provider "google" {
    project = "malachowski"
}

provider "cloudflare" {
  api_token = var.cloudflare_token
}

