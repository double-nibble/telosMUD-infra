# telosMUD-infra

Infrastructure-as-code for deploying [TelosMUD](../gomud) to real clusters.

Two environments, each a single-node **AWS EKS** cluster. Everything runs in-cluster (Postgres, Redis,
NATS, and the Telos services) on one Graviton node, fronted by AWS load balancers — a paid, managed
deployment chosen for operational simplicity. (This replaced an earlier Oracle Always-Free / k3s
design; see git history.)

- **Two GitHub Actions run the whole lifecycle:** **`up`** builds an environment end-to-end
  (`terraform apply` → secrets → issuers → deploy → rollout) and **`down`** destroys it. No manual
  `kubectl`/`aws`/DNS steps.
- **Terraform** (`terraform/`) provisions the VPC, EKS cluster + node group, cluster add-ons
  (EBS CSI, ingress-nginx, cert-manager, **external-dns**), IRSA roles, and an S3 backup bucket. State
  lives in an S3 bucket with native S3 locking.
- **Kustomize** (`k8s/`) deploys the app: a `base/` plus per-environment overlays. **external-dns**
  writes Route53 records and **cert-manager** issues Let's Encrypt certs automatically.
- **GitHub Actions** authenticate to AWS keylessly via GitHub OIDC.

Start with [PLAN.md](PLAN.md) for the design and cost model, then [RUNBOOK.md](RUNBOOK.md) for the
step-by-step bring-up.

**Deploying your own MUD (any cloud)?** See **[DEPLOYMENT.md](DEPLOYMENT.md)** — a vendor-neutral
guide for admins standing up a Telos MUD, covering prerequisites, content packs, configuration, and
hardening. (PLAN/RUNBOOK are the AWS EKS reference implementation of that guide.)

## Layout

```
terraform/
  modules/network/            # VPC (2 AZs, single NAT) — wraps terraform-aws-modules/vpc
  modules/eks/                # cluster + single-AZ node group + addons — wraps terraform-aws-modules/eks
  modules/cluster-bootstrap/  # gp3 StorageClass, ingress-nginx + cert-manager (helm), S3 backup bucket
  envs/{staging,production}/  # backend (S3+DynamoDB) + providers + tfvars per environment
k8s/
  base/                       # world, gate, account, postgres, redis, nats, jobs, observability
  overlays/{staging,production}/  # env deltas (insecure flags, TLS, secrets, ingress hosts)
  addons/                     # letsencrypt ClusterIssuer (applied post-cluster)
.github/workflows/            # terraform.yml, deploy.yml, validate.yml
scripts/                      # bootstrap-local.sh (writes tfvars)
```

## Getting started

Do the **one-time setup** in [RUNBOOK.md](RUNBOOK.md) (an OIDC role, an S3 state bucket, a GitHub OAuth
app, and the GH Actions secrets), then: **Actions → `up` → pick env → Run**. Tear down with **`down`**.
That's it — no local `kubectl`/`aws` needed. `scripts/bootstrap-local.sh` is only for an optional local
`terraform apply`.

## Status

Runs on AWS EKS with one-click `up`/`down` GitHub Actions. The only things you provision by hand are the
four one-time items in RUNBOOK §"One-time setup".
