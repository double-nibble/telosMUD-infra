# A VPC for the EKS cluster, built on the upstream terraform-aws-modules/vpc/aws module.
#
# Two AZs (EKS requires subnets in >= 2 AZs for the control plane), public + private subnets,
# and a SINGLE NAT gateway (cost lever — one NAT per env, not one-per-AZ). The managed node
# group is pinned to ONE private subnet by the eks module so a single-replica StatefulSet and
# its AZ-locked EBS volume always land in the same AZ (see modules/eks). Public subnets host the
# internet-facing NLBs (gate telnet + ingress-nginx web); private subnets host the nodes.

data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  # First two AZs in the region. Deterministic (the API returns them sorted), so re-applies are stable.
  azs = slice(data.aws_availability_zones.available.names, 0, 2)
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.13"

  name = "${var.name_prefix}-vpc"
  cidr = var.vpc_cidr
  azs  = local.azs

  # /20 private + /24 public per AZ, carved from the /16 vpc_cidr.
  private_subnets = [for i in range(length(local.azs)) : cidrsubnet(var.vpc_cidr, 4, i)]
  public_subnets  = [for i in range(length(local.azs)) : cidrsubnet(var.vpc_cidr, 8, i + 48)]

  enable_nat_gateway   = true
  single_nat_gateway   = true # one NAT for the whole env (cost); nodes egress through it
  enable_dns_hostnames = true

  # EKS discovers subnets for load balancers via these tags. Public = internet-facing LBs,
  # private = internal LBs. Without them, a Service type:LoadBalancer can't find a subnet.
  public_subnet_tags = {
    "kubernetes.io/role/elb" = "1"
  }
  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = "1"
  }
}
