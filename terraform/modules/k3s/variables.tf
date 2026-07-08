variable "public_ip" {
  type        = string
  description = "Public IP of the k3s instance (from the compute module)."
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
