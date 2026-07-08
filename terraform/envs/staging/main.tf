locals {
  name_prefix = "telos-staging"
  node_fqdn    = "staging.telos.double-nibble.com"
}

module "network" {
  source           = "../../modules/network"
  compartment_ocid = var.compartment_ocid
  name_prefix      = local.name_prefix
}

module "compute" {
  source              = "../../modules/compute"
  compartment_ocid    = var.compartment_ocid
  name_prefix         = local.name_prefix
  subnet_id           = module.network.subnet_id
  availability_domain = var.availability_domain
  image_ocid          = var.image_ocid
  ssh_public_key_path = var.ssh_public_key_path
  node_fqdn           = local.node_fqdn

  # Staging: half the free A1 pool by default (overridable to chase capacity).
  ocpus           = var.ocpus
  memory_gbs      = var.memory_gbs
  boot_volume_gbs = 50
}

module "k3s" {
  source               = "../../modules/k3s"
  public_ip            = module.compute.public_ip
  api_host             = local.node_fqdn
  instance_id          = module.compute.instance_id
  ssh_private_key_path = var.ssh_private_key_path
  kubeconfig_path      = "${path.root}/kubeconfig"
}
