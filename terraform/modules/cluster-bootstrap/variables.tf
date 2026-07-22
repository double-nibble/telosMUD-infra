variable "name_prefix" {
  type        = string
  description = "Prefix for named resources / tags, e.g. \"telos-staging\"."
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
