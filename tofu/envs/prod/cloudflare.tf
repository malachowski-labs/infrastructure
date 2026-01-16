data "cloudflare_zone" "this" {
  filter = {
    name = "malachowski.me"
  }
}



