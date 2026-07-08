output "instance_id" {
  value       = oci_core_instance.this.id
  description = "OCID of the k3s instance."
}

output "public_ip" {
  value       = oci_core_instance.this.public_ip
  description = "Ephemeral public IP of the instance. Point DNS + kubeconfig at this."
}

output "private_ip" {
  value       = oci_core_instance.this.private_ip
  description = "Private IP of the instance."
}
