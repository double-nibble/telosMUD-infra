# In-cluster platform that the app manifests assume exists: a default gp3 StorageClass (EBS CSI),
# ingress-nginx (fronted by an AWS NLB) for the web/OAuth + Grafana Ingresses, and cert-manager
# for Let's Encrypt. Also provisions the S3 bucket the pg-backup CronJob writes nightly dumps to.
#
# The helm + kubernetes providers are configured in the env root (they need the cluster endpoint,
# which only exists after the eks module applies) and inherited here — so this module runs after
# the cluster is up. See terraform/envs/*/main.tf.
#
# The letsencrypt ClusterIssuer is NOT created here: a kubernetes_manifest for a CRD-typed object
# fails at plan time before the CRD exists (a first-apply chicken-and-egg). It is applied as a
# cluster add-on with kubectl instead — see k8s/addons/letsencrypt-issuer.yaml + RUNBOOK.

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

# cert-manager (+ CRDs) — issues the Let's Encrypt web certs and the gate's telnet-TLS cert.
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
}

# ── Backups ──────────────────────────────────────────────────────────────────────────────────
# Nightly pg_dump destination (k8s/base/pg-backup.yaml). Versioned + private; old dumps expire.
# The CronJob authenticates with the out-of-band `backup-s3` Secret (RUNBOOK §Backups) — this just
# creates the bucket and exposes its name.
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
