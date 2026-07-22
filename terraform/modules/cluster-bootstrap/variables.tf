variable "name_prefix" {
  type        = string
  description = "Prefix for named resources / tags, e.g. \"telos-staging\"."
}

variable "region" {
  type        = string
  description = "AWS region (external-dns needs it to talk to Route53)."
}

variable "oidc_provider_arn" {
  type        = string
  description = "EKS IRSA OIDC provider ARN (from the eks module)."
}

variable "dns_zone_name" {
  type        = string
  description = "Route53 hosted-zone name external-dns + cert-manager manage records in, e.g. \"double-nibble.com\"."
}

variable "backup_bucket_name" {
  type        = string
  description = "Globally-unique S3 bucket name for nightly pg dumps."
}

variable "backup_retention_days" {
  type        = number
  default     = 30
  description = "Days before an old backup object (and noncurrent version) expires."
}

variable "ingress_nginx_chart_version" {
  type        = string
  default     = "4.11.3"
  description = "ingress-nginx Helm chart version."
}

variable "cert_manager_chart_version" {
  type        = string
  default     = "v1.16.2"
  description = "cert-manager Helm chart version."
}

variable "external_dns_chart_version" {
  type        = string
  default     = "1.15.0"
  description = "external-dns Helm chart version."
}
