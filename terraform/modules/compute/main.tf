# A single Always-Free A1 (Ampere/ARM) flex instance running k3s (installed via cloud-init).

resource "oci_core_instance" "this" {
  compartment_id      = var.compartment_ocid
  availability_domain = var.availability_domain
  display_name        = "${var.name_prefix}-k3s"
  shape               = "VM.Standard.A1.Flex"

  shape_config {
    ocpus         = var.ocpus
    memory_in_gbs = var.memory_gbs
  }

  source_details {
    source_type             = "image"
    source_id               = var.image_ocid
    boot_volume_size_in_gbs = var.boot_volume_gbs
  }

  create_vnic_details {
    subnet_id        = var.subnet_id
    assign_public_ip = true
  }

  metadata = {
    # pathexpand so a "~/..." key path works (file() alone does not expand ~).
    ssh_authorized_keys = file(pathexpand(var.ssh_public_key_path))
    user_data = base64encode(templatefile("${path.module}/cloud-init.yaml.tftpl", {
      open_tcp_ports = var.open_tcp_ports
    }))
  }

  # A1 free capacity is intermittent; ignore image drift so a re-apply doesn't rebuild.
  lifecycle {
    ignore_changes = [source_details[0].source_id]
  }
}
