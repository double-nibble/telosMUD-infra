# A single Always-Free A1 (Ampere/ARM) flex instance running k3s (installed via cloud-init).

locals {
  # Build cloud-config with yamlencode so indentation/quoting is ALWAYS valid YAML — a hand-
  # templated list is easy to mis-indent, and cloud-init silently drops user-data it can't parse.
  #
  # The instance has NO ephemeral public IP (assign_public_ip=false); Terraform attaches a
  # RESERVED public IP a few seconds after launch. So the k3s install waits for egress to come
  # up (the reserved IP attaching) before downloading. The API TLS SAN is the stable node_fqdn,
  # not the IP, so kubectl over the domain stays valid across instance recreations.
  runcmd = concat(
    # Open the app ports in the host firewall (Oracle images default-DROP INPUT except SSH).
    [for port in var.open_tcp_ports : "iptables -I INPUT -p tcp --dport ${port} -j ACCEPT"],
    [
      "netfilter-persistent save",
      "until curl -sfL https://get.k3s.io -o /tmp/install-k3s.sh; do echo 'waiting for egress (reserved IP attach)'; sleep 3; done",
      "INSTALL_K3S_EXEC=\"server --tls-san ${var.node_fqdn} --write-kubeconfig-mode 644\" sh /tmp/install-k3s.sh",
      "until kubectl --kubeconfig /etc/rancher/k3s/k3s.yaml get nodes >/dev/null 2>&1; do sleep 3; done",
    ],
  )

  cloud_config = "#cloud-config\n${yamlencode({
    package_update = true
    packages       = ["iptables-persistent"]
    runcmd         = local.runcmd
  })}"
}

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
    subnet_id = var.subnet_id
    # No ephemeral IP — a reserved public IP is attached below so the address is stable across
    # instance recreations. Egress still works (the reserved IP + IGW route); cloud-init waits
    # for it to attach before installing k3s.
    assign_public_ip = false
  }

  metadata = {
    # pathexpand so a "~/..." key path works (file() alone does not expand ~).
    ssh_authorized_keys = file(pathexpand(var.ssh_public_key_path))
    user_data           = base64encode(local.cloud_config)
  }

  # A1 free capacity is intermittent; ignore image drift so a re-apply doesn't rebuild.
  lifecycle {
    ignore_changes = [source_details[0].source_id]
  }
}

# The instance's primary VNIC + private IP, so the reserved public IP can attach to it.
data "oci_core_vnic_attachments" "primary" {
  compartment_id = var.compartment_ocid
  instance_id    = oci_core_instance.this.id
}

data "oci_core_private_ips" "primary" {
  vnic_id = data.oci_core_vnic_attachments.primary.vnic_attachments[0].vnic_id
}

# Reserved (static) public IP. On instance replacement Terraform re-associates the SAME address
# to the new primary private IP, so DNS never needs updating.
resource "oci_core_public_ip" "reserved" {
  compartment_id = var.compartment_ocid
  lifetime       = "RESERVED"
  display_name   = "${var.name_prefix}-ip"
  private_ip_id  = data.oci_core_private_ips.primary.private_ips[0].id
}
