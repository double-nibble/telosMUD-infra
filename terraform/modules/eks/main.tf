# The EKS cluster + one managed node group, built on the upstream terraform-aws-modules/eks/aws
# module. Deliberately single-node and single-AZ to mirror the old single-box k3s topology:
#
#   * ONE managed node group, pinned to ONE private subnet (node_subnet_ids[0]). Single-replica
#     StatefulSets (postgres, nats) use AZ-locked EBS volumes, so pod and volume must share an AZ.
#     Spreading nodes across AZs would let a reschedule strand a pod away from its EBS volume.
#   * Graviton (arm64) by default — the GHCR images are multi-arch, and arm64 is cheaper.
#
# EBS CSI: the aws-ebs-csi-driver addon runs with the NODE IAM role when no dedicated SA role is
# set, so AmazonEBSCSIDriverPolicy is attached to the node role below. gp3 StorageClass + the app
# PVCs live in modules/cluster-bootstrap and k8s/.

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.31"

  cluster_name    = var.cluster_name
  cluster_version = var.cluster_version

  # Public API endpoint so CI (OIDC) and your laptop can reach kube-apiserver via update-kubeconfig.
  # Restrict the source CIDRs in production if your operator/CI egress IPs are stable (auth is still
  # IAM/OIDC-gated regardless). GitHub-hosted runners have dynamic egress, so the default is open.
  cluster_endpoint_public_access       = true
  cluster_endpoint_public_access_cidrs = var.endpoint_public_access_cidrs

  # API-based access entries (not the legacy aws-auth ConfigMap). The principal that runs `apply`
  # gets cluster-admin so the helm/kubernetes providers in cluster-bootstrap can reach the cluster.
  authentication_mode                      = "API_AND_CONFIG_MAP"
  enable_cluster_creator_admin_permissions = true

  # Extra principals granted cluster-admin. IMPORTANT: do NOT list the principal that runs `apply`
  # here — it already gets cluster-admin via enable_cluster_creator_admin_permissions, and a second
  # access entry for the same principal_arn fails at apply with ResourceInUseException (plans green,
  # applies red). So the CI/apply role is intentionally NOT passed in; this is for OTHER principals
  # (e.g. a human operator's SSO role).
  access_entries = {
    for arn in var.admin_principal_arns : arn => {
      principal_arn = arn
      policy_associations = {
        admin = {
          policy_arn   = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope = { type = "cluster" }
        }
      }
    }
  }

  vpc_id     = var.vpc_id
  subnet_ids = var.node_subnet_ids # control-plane ENIs may use all private subnets

  cluster_addons = {
    coredns    = {}
    kube-proxy = {}
    vpc-cni = {
      # CRITICAL: the VPC CNI does NOT enforce Kubernetes NetworkPolicy unless this is on. k8s/base/
      # networkpolicy.yaml is a default-deny posture; without this it silently fails OPEN (every
      # policy ignored) — the opposite of what the manifest claims. k3s's kube-router enforced them
      # for free; on EKS it's opt-in. most_recent pulls a network-policy-agent new enough to carry
      # the kubelet-probe fix (older agents could block httpGet probes under default-deny).
      most_recent = true
      configuration_values = jsonencode({
        enableNetworkPolicy = "true"
      })
    }
    aws-ebs-csi-driver = {
      # Runs with the node role (below); no separate IRSA role needed for a single-node test.
      # FOLLOW-UP: for full IMDS lockdown (metadata hop_limit=1), move this to a dedicated IRSA role
      # so the controller doesn't depend on reaching the node instance profile via IMDS.
      most_recent = true
    }
  }

  eks_managed_node_groups = {
    default = {
      # Pinned to a SINGLE subnet/AZ so EBS volumes and their pods stay co-located.
      subnet_ids = [var.node_subnet_ids[0]]

      ami_type       = var.node_ami_type
      instance_types = [var.node_instance_type]

      min_size     = var.node_min_size
      max_size     = var.node_max_size
      desired_size = var.node_desired_size

      # Enforce IMDSv2 (token-required) so a bare IMDSv1 GET from a compromised pod can't lift the
      # node role. hop_limit stays 2 so the node-role-based EBS CSI controller can still reach IMDS;
      # dropping to 1 (blocks pods entirely) requires moving EBS CSI to IRSA first (see addon note).
      metadata_options = {
        http_endpoint               = "enabled"
        http_tokens                 = "required"
        http_put_response_hop_limit = 2
      }

      # The EBS CSI controller/node pods authenticate with the node role by default.
      iam_role_additional_policies = {
        ebs_csi = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
      }
    }
  }

  tags = {
    Project     = "telosmud"
    Environment = var.name_prefix
  }
}
