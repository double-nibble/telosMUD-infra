output "instance_id" {
  value       = oci_core_instance.this.id
  description = "OCID of the k3s instance."
}

output "public_ip" {
  value       = oci_core_public_ip.reserved.ip_address
  description = "Reserved (static) public IP. Point the node_fqdn DNS A-record here; stable across instance recreations."
}

output "private_ip" {
  value       = oci_core_instance.this.private_ip
  description = "Private IP of the instance."
}
