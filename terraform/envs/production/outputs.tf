output "cluster_name" {
  value       = module.eks.cluster_name
  description = "EKS cluster name."
}

output "region" {
  value       = var.region
  description = "AWS region the cluster runs in."
}

output "configure_kubectl" {
  value       = "aws eks update-kubeconfig --name ${module.eks.cluster_name} --region ${var.region}"
  description = "Run this to point kubectl at the cluster."
}

output "ingress_lb_hint" {
  value       = "kubectl -n ${module.cluster_bootstrap.ingress_namespace} get svc ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'"
  description = "How to read the ingress NLB hostname to CNAME the web/grafana hosts at."
}

output "backup_bucket" {
  value       = module.cluster_bootstrap.backup_bucket
  description = "S3 bucket for pg backups (wire into the backup-s3 Secret)."
}

output "vpc_id" {
  value       = module.network.vpc_id
  description = "VPC ID (used by the teardown LB-drain check)."
}
