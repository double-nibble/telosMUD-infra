output "public_ip" {
  value       = module.compute.public_ip
  description = "Node public IP. Point <domain> here; telnet <ip> 4000 (TLS in prod)."
}

output "kubeconfig" {
  value       = module.k3s.kubeconfig
  sensitive   = true
  description = "Kubeconfig. `terraform output -raw kubeconfig > ~/.kube/telos-production`."
}
