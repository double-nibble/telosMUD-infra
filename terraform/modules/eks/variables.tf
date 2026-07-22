variable "name_prefix" {
  type        = string
  description = "Prefix for named resources / tags, e.g. \"telos-staging\"."
}

variable "cluster_name" {
  type        = string
  description = "EKS cluster name."
}

variable "cluster_version" {
  type        = string
  default     = "1.33"
  description = "Kubernetes control-plane version."
}

variable "vpc_id" {
  type        = string
  description = "VPC ID (from the network module)."
}

variable "node_subnet_ids" {
  type        = list(string)
  description = "Private subnet IDs. The node group is pinned to the first one (single AZ); the control plane may span all."
}

variable "node_instance_type" {
  type        = string
  default     = "t4g.large"
  description = "EC2 instance type for the node group. Graviton (arm64) by default. Bump to t4g.xlarge (16 GB) if the LGTM stack is memory-tight."
}

variable "node_ami_type" {
  type        = string
  default     = "AL2023_ARM_64_STANDARD"
  description = "EKS managed node AMI type. Must match node_instance_type arch (AL2023_ARM_64_STANDARD for t4g/Graviton; AL2023_x86_64_STANDARD for x86)."
}

variable "node_min_size" {
  type        = number
  default     = 1
  description = "Node group minimum size."
}

variable "node_max_size" {
  type        = number
  default     = 2
  description = "Node group maximum size."
}

variable "node_desired_size" {
  type        = number
  default     = 1
  description = "Node group desired size (single node mirrors the old k3s box)."
}

variable "admin_principal_arns" {
  type        = list(string)
  default     = []
  description = "Extra IAM principal ARNs granted cluster-admin via an access entry. Do NOT include the principal that runs `apply` (it already gets admin via the cluster-creator flag; a duplicate access entry fails at apply)."
}

variable "endpoint_public_access_cidrs" {
  type        = list(string)
  default     = ["0.0.0.0/0"]
  description = "CIDRs allowed to reach the public kube-apiserver endpoint. Default open (GitHub runners have dynamic egress); restrict in production if your operator/CI IPs are stable."
}
