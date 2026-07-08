# Waits for cloud-init (k3s install) to finish, then fetches the kubeconfig and rewrites the
# server URL from 127.0.0.1 to the public IP so it works from CI / your laptop.

resource "null_resource" "wait_for_k3s" {
  triggers = {
    instance_id = var.instance_id
  }

  connection {
    type        = "ssh"
    host        = var.public_ip
    user        = var.ssh_user
    private_key = file(pathexpand(var.ssh_private_key_path))
    timeout     = "10m"
  }

  # Block until cloud-init (and therefore the k3s install) has fully completed.
  provisioner "remote-exec" {
    inline = [
      "cloud-init status --wait || true",
      "sudo test -f /etc/rancher/k3s/k3s.yaml",
    ]
  }
}

# Pull the kubeconfig over SSH and point it at the public IP.
resource "null_resource" "fetch_kubeconfig" {
  depends_on = [null_resource.wait_for_k3s]

  triggers = {
    instance_id = var.instance_id
  }

  provisioner "local-exec" {
    command = <<-EOT
      ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -i ${pathexpand(var.ssh_private_key_path)} ${var.ssh_user}@${var.public_ip} \
        'sudo cat /etc/rancher/k3s/k3s.yaml' \
        | sed 's/127.0.0.1/${var.api_host}/' > ${var.kubeconfig_path}
      chmod 600 ${var.kubeconfig_path}
    EOT
  }
}

data "local_file" "kubeconfig" {
  depends_on = [null_resource.fetch_kubeconfig]
  filename   = var.kubeconfig_path
}
