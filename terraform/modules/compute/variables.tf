variable "compartment_ocid" {
  type        = string
  description = "OCID of the compartment to launch the instance in."
}

variable "name_prefix" {
  type        = string
  description = "Prefix for named resources, e.g. \"telos-staging\"."
}

variable "subnet_id" {
  type        = string
  description = "OCID of the subnet (from the network module)."
}

variable "availability_domain" {
  type        = string
  description = "Availability domain name for the instance, e.g. \"Uocm:US-ASHBURN-AD-1\"."
}

variable "image_ocid" {
  type        = string
  description = "OCID of the Ubuntu 22.04 aarch64 image for the chosen region. Find via the OCI console or `oci compute image list`."
}

variable "ssh_public_key_path" {
  type        = string
  description = "Path to the SSH public key injected into the instance."
}

variable "ocpus" {
  type        = number
  default     = 2
  description = "A1.Flex OCPU count (free-tier pool total is 4 across all VMs)."
}

variable "memory_gbs" {
  type        = number
  default     = 12
  description = "A1.Flex memory in GB (free-tier pool total is 24 across all VMs)."
}

variable "boot_volume_gbs" {
  type        = number
  default     = 50
  description = "Boot volume size in GB (free-tier pool total is 200 across all volumes)."
}

variable "open_tcp_ports" {
  type        = list(number)
  default     = [22, 80, 443, 4000, 6443]
  description = "Ports cloud-init opens in the instance host firewall (iptables), before the image's default REJECT. Must match the network security list. 6443 = k3s API."
}

variable "node_fqdn" {
  type        = string
  description = "Stable DNS name for the node (e.g. staging.telos.example.com). Used as the k3s API TLS SAN so kubectl works over the domain regardless of the underlying IP. Point this at the reserved public IP output."
}
