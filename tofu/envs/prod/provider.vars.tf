variable "cloudflare_token" {
  description = "Cloudflare API token"
  type        = string
  sensitive   = true
}

variable "google_cloud_project_name" {
  type    = string
  default = "malachowski"
}
