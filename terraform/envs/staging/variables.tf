variable "region" {
  type        = string
  description = "OCI region, e.g. us-ashburn-1."
}

variable "tenancy_ocid" {
  type        = string
  description = "Tenancy OCID."
}

variable "compartment_ocid" {
  type        = string
  description = "Compartment OCID for TelosMUD resources."
}

variable "availability_domain" {
  type        = string
  description = "Availability domain, e.g. \"Uocm:US-ASHBURN-AD-1\"."
}

variable "image_ocid" {
  type        = string
  description = "OCID of the Ubuntu 22.04 aarch64 image in this region."
}

variable "ssh_public_key_path" {
  type        = string
  description = "Path to the SSH public key to inject into the VM."
}

variable "ssh_private_key_path" {
  type        = string
  description = "Path to the matching SSH private key (used to fetch the kubeconfig)."
}
