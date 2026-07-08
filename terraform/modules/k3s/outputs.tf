output "kubeconfig" {
  value       = data.local_file.kubeconfig.content
  sensitive   = true
  description = "Kubeconfig for the cluster, with the server rewritten to the public IP."
}

output "kubeconfig_path" {
  value       = var.kubeconfig_path
  description = "Local path the kubeconfig was written to."
}
