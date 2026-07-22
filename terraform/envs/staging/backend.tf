terraform {
  required_version = ">= 1.11" # native S3 state locking (use_lockfile) below

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = ">= 2.13, < 3.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 2.30"
    }
  }

  # State in an S3 bucket with native S3 locking (use_lockfile — no DynamoDB table needed). Create the
  # bucket ONCE, out of band, before the first `terraform init` (see RUNBOOK §0). The state bucket
  # region is independent of var.region (where the cluster deploys) — it just has to be a real region.
  backend "s3" {
    bucket       = "telosmud-tfstate"
    key          = "staging/terraform.tfstate"
    region       = "us-east-1"
    use_lockfile = true
    encrypt      = true
  }
}

provider "aws" {
  region = var.region
}

# The kubernetes/helm providers talk to the cluster the eks module creates. Auth via the AWS CLI's
# `eks get-token` (the aws CLI must be on PATH — CI installs it, local runs need `aws configure`).
# On a first apply these attributes are unknown until the cluster exists; Terraform defers the
# cluster-bootstrap resources until then.
provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", var.region]
  }
}

provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", var.region]
    }
  }
}
