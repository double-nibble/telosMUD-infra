variable "region" {
  type        = string
  default     = "us-east-1"
  description = "AWS region to deploy the cluster into."
}

variable "cluster_version" {
  type        = string
  default     = "1.36"
  description = "EKS Kubernetes control-plane version."
}

variable "vpc_cidr" {
  type        = string
  default     = "10.20.0.0/16"
  description = "CIDR block for the production VPC (distinct from staging's 10.10/16)."
}

variable "dns_zone_name" {
  type        = string
  default     = "telos.double-nibble.com"
  description = "The production Route53 subzone (created + delegated by Terraform); external-dns + cert-manager are scoped to it."
}

variable "root_dns_zone_name" {
  type        = string
  default     = "double-nibble.com"
  description = "Pre-existing root hosted zone you own, where the subzone NS delegation is written."
}

variable "node_instance_type" {
  type        = string
  default     = "t4g.large"
  description = "Node group EC2 instance type (Graviton/arm64 default). Bump to t4g.xlarge (16 GB) if the LGTM stack is memory-tight."
}

variable "node_ami_type" {
  type        = string
  default     = "AL2023_ARM_64_STANDARD"
  description = "EKS node AMI type. Must match node_instance_type arch."
}

variable "admin_principal_arns" {
  type        = list(string)
  default     = []
  description = "Extra IAM principal ARNs granted cluster-admin (e.g. the CI OIDC role ARN)."
}
