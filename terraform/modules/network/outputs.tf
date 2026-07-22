output "vpc_id" {
  value       = module.vpc.vpc_id
  description = "ID of the VPC."
}

output "private_subnet_ids" {
  value       = module.vpc.private_subnets
  description = "Private subnet IDs (nodes attach here; one is used for the single-AZ node group)."
}

output "public_subnet_ids" {
  value       = module.vpc.public_subnets
  description = "Public subnet IDs (internet-facing NLBs land here)."
}
