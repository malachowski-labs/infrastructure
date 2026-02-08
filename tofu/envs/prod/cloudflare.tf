data "cloudflare_zone" "this" {
  filter = {
    name = "malachowski.me"
  }
}

resource "cloudflare_dns_record" "this" {
  type    = "A"
  zone_id = data.cloudflare_zone.this.id
  name    = "malachowski.me"
  content = hcloud_load_balancer.this.ipv4
  ttl     = 1
  proxied = true
}

resource "cloudflare_dns_record" "wildcard" {
  type    = "A"
  zone_id = data.cloudflare_zone.this.id
  name    = "*.malachowski.me"
  content = hcloud_load_balancer.this.ipv4
  ttl     = 1
  proxied = true
}

