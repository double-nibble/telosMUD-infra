output "subnet_id" {
  value       = oci_core_subnet.public.id
  description = "OCID of the public subnet the VM attaches to."
}

output "vcn_id" {
  value       = oci_core_vcn.this.id
  description = "OCID of the VCN."
}
