locals {
  any_api_source = [
    "0.0.0.0/0",
    "::/0"
  ]
}

module "talos" {
  source = "hcloud-talos/talos/hcloud"
  version = "v2.23.1"
  hcloud_token = var.hcloud_token

  talos_version = "v1.11.0"

  cluster_name    = "prod.malachowski.me"
  datacenter_name = "hel1-dc2"

  control_plane_count       = 1
  control_plane_server_type = "cx23"

  firewall_kube_api_source  = local.any_api_source
  firewall_talos_api_source = local.any_api_source

  disable_arm = true
}
