output "kubeconfig" {
  value     = module.talos.kubeconfig
  sensitive = true
}
