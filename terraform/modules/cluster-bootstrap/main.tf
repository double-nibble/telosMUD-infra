# In-cluster platform that the app manifests assume exists: a default gp3 StorageClass (EBS CSI),
# ingress-nginx (fronted by an AWS NLB) for the web/OAuth + Grafana Ingresses, cert-manager for
# Let's Encrypt, and external-dns to write Route53 records from the live NLB hostnames. Also
# provisions the S3 bucket + IRSA role the pg-backup CronJob uses.
#
# DNS + certs are FULLY AUTOMATED (no manual records, no API tokens): external-dns and cert-manager
# both reach Route53 via IRSA roles created below and scoped to the one hosted zone. external-dns
# reads the web Ingress host + the gate Service's external-dns hostname annotation and creates the
# CNAMEs; cert-manager does DNS-01 for the gate cert and HTTP-01 for the web cert.
#
# The helm + kubernetes providers are configured in the env root (they need the cluster endpoint,
# which only exists after the eks module applies) and inherited here — so this module runs after
# the cluster is up. See terraform/envs/*/main.tf.
#
# The ClusterIssuers are NOT created here: a kubernetes_manifest for a CRD-typed object fails at plan
# time before the CRD exists (a first-apply chicken-and-egg). They are applied by the deploy workflow
# after cert-manager is up — see k8s/addons/*.yaml.

data "aws_route53_zone" "this" {
  name         = var.dns_zone_name
  private_zone = false
}

# IRSA roles for the Route53-writing controllers, scoped to just this one hosted zone. The upstream
# module wires the OIDC trust + the AWS-recommended policies (no hand-rolled JSON).
module "external_dns_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.44"

  role_name                     = "${var.name_prefix}-external-dns"
  attach_external_dns_policy    = true
  external_dns_hosted_zone_arns = [data.aws_route53_zone.this.arn]

  oidc_providers = {
    main = {
      provider_arn               = var.oidc_provider_arn
      namespace_service_accounts = ["external-dns:external-dns"]
    }
  }
}

module "cert_manager_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.44"

  role_name                     = "${var.name_prefix}-cert-manager"
  attach_cert_manager_policy    = true
  cert_manager_hosted_zone_arns = [data.aws_route53_zone.this.arn]

  oidc_providers = {
    main = {
      provider_arn               = var.oidc_provider_arn
      namespace_service_accounts = ["cert-manager:cert-manager"]
    }
  }
}

# Default StorageClass: gp3 EBS, encrypted, bound when the first consumer pod schedules (so the
# volume is created in the pod's AZ — which, with the single-AZ node group, is always the node's AZ).
resource "kubernetes_storage_class_v1" "gp3" {
  metadata {
    name = "gp3"
    annotations = {
      "storageclass.kubernetes.io/is-default-class" = "true"
    }
  }
  storage_provisioner    = "ebs.csi.aws.com"
  reclaim_policy         = "Delete"
  volume_binding_mode    = "WaitForFirstConsumer"
  allow_volume_expansion = true
  parameters = {
    type      = "gp3"
    encrypted = "true"
  }
}

# ingress-nginx — one internet-facing NLB serves the web (:443/:80) Ingresses. Raw-TCP telnet is a
# SEPARATE NLB owned by the gate Service (k8s/base/gate.yaml), not this controller.
resource "helm_release" "ingress_nginx" {
  name             = "ingress-nginx"
  repository       = "https://kubernetes.github.io/ingress-nginx"
  chart            = "ingress-nginx"
  version          = var.ingress_nginx_chart_version
  namespace        = "ingress-nginx"
  create_namespace = true

  # NLB (not a classic ELB) via the in-tree AWS cloud provider; preserve client source IPs.
  set {
    name  = "controller.service.type"
    value = "LoadBalancer"
  }
  set {
    name  = "controller.service.annotations.service\\.beta\\.kubernetes\\.io/aws-load-balancer-type"
    value = "nlb"
  }
  set {
    name  = "controller.service.externalTrafficPolicy"
    value = "Local"
  }
}

# cert-manager (+ CRDs) — issues the Let's Encrypt web certs (HTTP-01) and the gate's telnet-TLS cert
# (DNS-01 via Route53). Its ServiceAccount is annotated with the IRSA role so the DNS-01 solver can
# write TXT challenge records without any AWS keys.
resource "helm_release" "cert_manager" {
  name             = "cert-manager"
  repository       = "https://charts.jetstack.io"
  chart            = "cert-manager"
  version          = var.cert_manager_chart_version
  namespace        = "cert-manager"
  create_namespace = true

  set {
    name  = "installCRDs"
    value = "true"
  }
  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = module.cert_manager_irsa.iam_role_arn
  }
  # cert-manager must use the projected SA token to assume the IRSA role.
  set {
    name  = "securityContext.fsGroup"
    value = "1001"
  }
}

# external-dns — watches the web Ingress (host) and the gate Service (external-dns hostname
# annotation) and writes the matching CNAMEs into Route53, targeting whatever NLB hostnames the AWS
# cloud provider assigned. policy=sync so records are also REMOVED on teardown; txtOwnerId keeps
# staging and production from fighting over the shared zone.
resource "helm_release" "external_dns" {
  name             = "external-dns"
  repository       = "https://kubernetes-sigs.github.io/external-dns/"
  chart            = "external-dns"
  version          = var.external_dns_chart_version
  namespace        = "external-dns"
  create_namespace = true

  set {
    name  = "provider.name"
    value = "aws"
  }
  set {
    name  = "env[0].name"
    value = "AWS_DEFAULT_REGION"
  }
  set {
    name  = "env[0].value"
    value = var.region
  }
  set {
    name  = "policy"
    value = "sync"
  }
  set {
    name  = "txtOwnerId"
    value = var.name_prefix
  }
  set {
    name  = "domainFilters[0]"
    value = var.dns_zone_name
  }
  set {
    name  = "sources[0]"
    value = "ingress"
  }
  set {
    name  = "sources[1]"
    value = "service"
  }
  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = module.external_dns_irsa.iam_role_arn
  }
}

# ── Backups ──────────────────────────────────────────────────────────────────────────────────
# Nightly pg_dump destination (k8s/base/pg-backup.yaml). Versioned + private; old dumps expire.
# The CronJob authenticates with the `backup-s3` Secret, which the deploy workflow creates from
# OPTIONAL GH secrets (skipped if unset — backups just don't run, fine for a throwaway env). This
# just creates the bucket + exposes its name. FOLLOW-UP: move pg-backup to IRSA (like external-dns /
# cert-manager above) to drop the static key entirely.
resource "aws_s3_bucket" "backups" {
  bucket = var.backup_bucket_name

  # This is a throwaway test-env bucket. force_destroy lets `terraform destroy` empty it — a versioned
  # bucket is otherwise BucketNotEmpty (delete markers + noncurrent versions survive `aws s3 rm`) and
  # blocks the whole destroy. FOLLOW-UP: for a durable prod backup store, drop force_destroy and add
  # S3 Object Lock (which requires object-lock-enabled at bucket creation).
  force_destroy = true

  tags = {
    Project     = "telosmud"
    Environment = var.name_prefix
  }
}

resource "aws_s3_bucket_public_access_block" "backups" {
  bucket                  = aws_s3_bucket.backups.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# These dumps are a full accounts/PII export — refuse any non-TLS access to them.
resource "aws_s3_bucket_policy" "backups_tls_only" {
  bucket = aws_s3_bucket.backups.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "DenyInsecureTransport"
      Effect    = "Deny"
      Principal = "*"
      Action    = "s3:*"
      Resource = [
        aws_s3_bucket.backups.arn,
        "${aws_s3_bucket.backups.arn}/*",
      ]
      Condition = { Bool = { "aws:SecureTransport" = "false" } }
    }]
  })
}

resource "aws_s3_bucket_versioning" "backups" {
  bucket = aws_s3_bucket.backups.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "backups" {
  bucket = aws_s3_bucket.backups.id
  rule {
    id     = "expire-old-dumps"
    status = "Enabled"
    filter {}
    expiration {
      days = var.backup_retention_days
    }
    noncurrent_version_expiration {
      noncurrent_days = var.backup_retention_days
    }
  }
}
