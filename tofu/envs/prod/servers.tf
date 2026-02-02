locals {
  any_api_source = [
    "0.0.0.0/0",
    "::/0"
  ]
}

module "talos" {
  source       = "hcloud-talos/talos/hcloud"
  version      = "v2.23.1"
  hcloud_token = var.hcloud_token

  talos_version = "v1.11.0"

  cluster_name    = "prod.malachowski.me"
  datacenter_name = "hel1-dc2"

  control_plane_count       = 1
  control_plane_server_type = "cx23"

  firewall_kube_api_source  = local.any_api_source
  firewall_talos_api_source = local.any_api_source

  disable_arm = true

  kube_api_extra_args = {
    "service-account-issuer"   = "https://oidc.malachowski.me"
    "service-account-jwks-uri" = "https://oidc.malachowski.me/openid/v1/jwks"
    "api-audiences"            = "https://oidc.malachowski.me"
  }
}

resource "hcloud_load_balancer" "this" {
  name               = "prod-malachowski-me-lb"
  load_balancer_type = "lb11"
  location           = "hel1"
}

resource "hcloud_load_balancer_network" "this" {
  load_balancer_id = hcloud_load_balancer.this.id
  network_id       = module.talos.hetzner_network_id
}

resource "hcloud_load_balancer_target" "this" {
  depends_on = [hcloud_load_balancer_network.this]

  type             = "label_selector"
  load_balancer_id = hcloud_load_balancer.this.id
  label_selector   = "role=control-plane"
  use_private_ip   = true
}


