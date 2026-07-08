terraform {
  required_version = ">= 1.6"

  required_providers {
    oci = {
      source  = "oracle/oci"
      version = ">= 5.0"
    }
    null = {
      source  = "hashicorp/null"
      version = ">= 3.2"
    }
    local = {
      source  = "hashicorp/local"
      version = ">= 2.4"
    }
  }

  # State in an OCI Object Storage bucket (S3-compatible). Create the bucket first, then set
  # the values below. Auth uses a Customer Secret Key (Access/Secret) via AWS_ env vars or a
  # shared credentials file — see RUNBOOK. Comment this block out to use local state initially.
  #backend "s3" {
  #  bucket                      = "telosmud-tfstate"          # TODO: your bucket name
  #  key                         = "staging/terraform.tfstate"
  #  region                      = "us-ashburn-1"
  #  endpoints                   = { s3 = "https://idknnsi3cdrb.compat.objectstorage.us-ashburn-1.oraclecloud.com" }
  #  skip_region_validation      = true
  #  skip_credentials_validation = true
  #  skip_requesting_account_id  = true
  #  skip_s3_checksum            = true
  #  use_path_style              = true
  #}
}

provider "oci" {
  # Auth via ~/.oci/config (DEFAULT profile) or TF_VAR_/env vars. See RUNBOOK step 0.
  region = var.region
}
