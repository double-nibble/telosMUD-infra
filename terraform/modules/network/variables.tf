variable "name_prefix" {
  type        = string
  description = "Prefix for named resources, e.g. \"telos-staging\"."
}

variable "vpc_cidr" {
  type        = string
  default     = "10.0.0.0/16"
  description = "CIDR block for the VPC. Subnets are carved from this."
}
