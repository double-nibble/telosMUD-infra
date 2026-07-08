locals {
  name_prefix = "telos-production"
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

  # Production: the other half of the free A1 pool (2 OCPU / 12 GB / 50 GB).
  ocpus           = 2
  memory_gbs      = 12
  boot_volume_gbs = 50
}

module "k3s" {
  source               = "../../modules/k3s"
  public_ip            = module.compute.public_ip
  instance_id          = module.compute.instance_id
  ssh_private_key_path = var.ssh_private_key_path
  kubeconfig_path      = "${path.root}/kubeconfig"
}
