output "backup_bucket" {
  value       = aws_s3_bucket.backups.bucket
  description = "S3 bucket name for pg backups (wire into the backup-s3 Secret)."
}

output "ingress_namespace" {
  value       = helm_release.ingress_nginx.namespace
  description = "Namespace where ingress-nginx (and its NLB Service) live. Get the NLB hostname with: kubectl -n <ns> get svc ingress-nginx-controller."
}
