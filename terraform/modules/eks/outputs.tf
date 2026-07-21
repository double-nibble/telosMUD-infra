output "cluster_name" {
  value       = module.eks.cluster_name
  description = "EKS cluster name (feed to `aws eks update-kubeconfig`)."
}

output "cluster_endpoint" {
  value       = module.eks.cluster_endpoint
  description = "kube-apiserver endpoint."
}

output "cluster_certificate_authority_data" {
  value       = module.eks.cluster_certificate_authority_data
  description = "Base64 cluster CA, for configuring the kubernetes/helm providers."
}

output "oidc_provider_arn" {
  value       = module.eks.oidc_provider_arn
  description = "IRSA OIDC provider ARN (for future service-account IAM roles, e.g. pg-backup)."
}

output "node_iam_role_name" {
  value       = module.eks.eks_managed_node_groups["default"].iam_role_name
  description = "Node group IAM role name (attach extra policies here, e.g. S3 for backups)."
}
