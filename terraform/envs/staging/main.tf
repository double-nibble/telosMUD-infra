locals {
  name_prefix  = "telos-staging"
  cluster_name = "telos-staging"
  # Stable DNS name for the web/OAuth site. CNAME this at the ingress-nginx NLB hostname after apply
  # (see RUNBOOK §DNS). The telnet gate has its own NLB (k8s/base/gate.yaml).
  node_fqdn = "staging.telos.double-nibble.com"
}

data "aws_caller_identity" "current" {}

module "network" {
  source      = "../../modules/network"
  name_prefix = local.name_prefix
  vpc_cidr    = var.vpc_cidr
}

module "eks" {
  source          = "../../modules/eks"
  name_prefix     = local.name_prefix
  cluster_name    = local.cluster_name
  cluster_version = var.cluster_version

  vpc_id          = module.network.vpc_id
  node_subnet_ids = module.network.private_subnet_ids

  node_instance_type = var.node_instance_type
  node_ami_type      = var.node_ami_type

  # Grant the CI OIDC role (if set) cluster-admin so deploy.yml can kubectl apply.
  admin_principal_arns = var.admin_principal_arns
}

module "cluster_bootstrap" {
  source            = "../../modules/cluster-bootstrap"
  name_prefix       = local.name_prefix
  region            = var.region
  oidc_provider_arn = module.eks.oidc_provider_arn
  dns_zone_name     = var.dns_zone_name
  # Globally-unique, no user input: account-scoped bucket name.
  backup_bucket_name = "telos-staging-backups-${data.aws_caller_identity.current.account_id}"
}
