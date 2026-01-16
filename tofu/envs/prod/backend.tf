terraform {
  backend "gcs" {
    bucket = "state.infra.malachowski.me"
    prefix = "prod"
  }
}
