variable "compartment_ocid" {
  type        = string
  description = "OCID of the compartment to create network resources in."
}

variable "name_prefix" {
  type        = string
  description = "Prefix for named resources, e.g. \"telos-staging\"."
}

variable "vcn_cidr" {
  type        = string
  default     = "10.0.0.0/16"
  description = "CIDR block for the VCN."
}

variable "subnet_cidr" {
  type        = string
  default     = "10.0.1.0/24"
  description = "CIDR block for the public subnet."
}

variable "ingress_tcp_ports" {
  type        = list(number)
  default     = [22, 80, 443, 4000, 6443]
  description = "TCP ports opened to the internet at the security-list level. 22=ssh, 80=ACME http-01 fallback, 443=web/OAuth, 4000=telnet gate, 6443=k3s API (TLS+token auth; needed for remote kubectl/CI — restrict source later if desired)."
}
