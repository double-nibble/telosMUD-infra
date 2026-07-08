variable "public_ip" {
  type        = string
  description = "Reserved public IP of the k3s instance (used for SSH connectivity)."
}

variable "api_host" {
  type        = string
  description = "Stable hostname the kubeconfig server points at (the node_fqdn / k3s API TLS SAN). kubectl connects here; it must resolve (DNS A-record) to public_ip."
}

variable "instance_id" {
  type        = string
  description = "Instance OCID; used only to re-trigger the fetch when the VM is replaced."
}

variable "ssh_private_key_path" {
  type        = string
  description = "Path to the SSH private key matching the public key injected into the VM."
}

variable "ssh_user" {
  type        = string
  default     = "ubuntu"
  description = "SSH login user for the image (ubuntu for the Ubuntu image)."
}

variable "kubeconfig_path" {
  type        = string
  description = "Local path to write the fetched kubeconfig to (typically a 'kubeconfig' file in the env root)."
}
