data "cloudflare_zone" "this" {
  filter = {
    name = "malachowski.me"
  }
}

resource "cloudflare_record" "this" {
  type = "A"
  zone_id = data.cloudflare_zone.this.id
  name = "malachowski.me"
  value = hcloud_load_balancer.this.ipv4
}

resource "cloudflare_record" "wildcard" {
  type = "A"
  zone_id = data.cloudflare_zone.this.id
  name = "*.malachowski.me"
  value = hcloud_load_balancer.this.ipv4
}

