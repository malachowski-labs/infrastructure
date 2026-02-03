locals {
  any_api_source = [
    "0.0.0.0/0",
    "::/0"
  ]

  control_plane_nodes = [
    for i in range(0, 1) : {
      id     = i + 1
      name   = "prod-malachowski-me-cp-${i}"
      labels = { role = "control-plane" }
      type   = "cx33"
    }
  ]

  workers_nodes = [
    for i in range(0, 0) : {
      id     = i + 1
      name   = "prod-malachowski-me-w-${i}"
      labels = { role = "worker" }
      type   = "cpx22"
    }
  ]
}

module "talos" {
  source       = "hcloud-talos/talos/hcloud"
  version      = "v3.0.0-next.1"
  hcloud_token = var.hcloud_token

  talos_version      = "v1.12.0"
  kubernetes_version = "v1.35.0"

  cluster_name  = "prod.malachowski.me"
  location_name = "hel1"

  control_plane_nodes = local.control_plane_nodes
  worker_nodes        = local.workers_nodes

  firewall_kube_api_source  = local.any_api_source
  firewall_talos_api_source = local.any_api_source

  disable_arm = true

  kube_api_extra_args = {
    "service-account-issuer"   = "https://oidc.malachowski.me"
    "service-account-jwks-uri" = "https://oidc.malachowski.me/openid/v1/jwks"
    "api-audiences"            = "https://oidc.malachowski.me"
  }

  control_plane_allow_schedule = true
  kubeconfig_endpoint_mode     = "public_endpoint"
  cluster_api_host             = hcloud_load_balancer.this.ipv4
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

resource "hcloud_load_balancer_service" "this" {
  load_balancer_id = hcloud_load_balancer.this.id
  protocol         = "tcp"
  listen_port      = 6443
  destination_port = 6443
}


