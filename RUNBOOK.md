# TelosMUD deploy runbook

Step-by-step bring-up of a fresh environment on **AWS EKS**. Do `staging` first, then `production`.
See [PLAN.md](PLAN.md) for the design and rationale.

## 0. Prerequisites (one-time)

- An **AWS account** with credentials that can create EKS/VPC/EC2/IAM/S3 resources.
- Configure the **`aws` CLI**: `aws configure` (or an SSO / assumed-role profile). This is the only
  per-collaborator setup — Terraform authenticates from your ambient AWS credentials.
- Install locally: `terraform`, `aws` CLI, `kubectl`, `kustomize`, `sops`, `age`, `helm` (Terraform
  drives helm, but it's handy for debugging).

### Bootstrap your local config (idempotent)

```sh
scripts/bootstrap-local.sh
```

Writes the gitignored `terraform/envs/{staging,production}/terraform.tfvars` with your region and the
default node size / VPC CIDR. Edit that file to change the node instance type (e.g. `t4g.xlarge` for
16 GB) or region. No secrets are involved.

### Terraform remote state (create ONCE, before the first `terraform init`)

The S3 state bucket named in `terraform/envs/*/backend.tf` must exist first. Locking is native S3
(`use_lockfile`, Terraform ≥1.11) — **no DynamoDB table needed**. The bucket name is **globally
unique across all of AWS**; if `telosmud-tfstate` is taken, pick another and update `bucket` in both
`terraform/envs/{staging,production}/backend.tf`.

```sh
aws s3api create-bucket --bucket telosmud-tfstate --region us-east-1
aws s3api put-bucket-versioning --bucket telosmud-tfstate \
  --versioning-configuration Status=Enabled
# State holds the cluster CA + any secrets in state — lock the bucket down:
aws s3api put-public-access-block --bucket telosmud-tfstate \
  --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
```

The IAM role your CI/laptop uses needs `s3:ListBucket` on the bucket and `s3:GetObject`/`s3:PutObject`/
`s3:DeleteObject` on `telosmud-tfstate/*` (the state read/write + lockfile).

### CI auth (GitHub OIDC → IAM role)

CI is keyless: the workflows assume an IAM role via GitHub's OIDC token (no access keys in secrets).
Create an IAM OIDC identity provider for `token.actions.githubusercontent.com`, then a role whose
trust policy allows this repo's OIDC subject, stored as the repo secret **`AWS_ROLE_ARN`**. This role
is the Terraform apply principal, so `enable_cluster_creator_admin_permissions` already grants it
cluster-admin — `deploy.yml` can `kubectl apply` with it. (Do **not** also list it in
`admin_principal_arns`; a duplicate EKS access entry for the same principal fails at apply.)

> **Least-privilege the trust policy.** A `repo:<owner>/telosMUD-infra:*` subject matches *every* ref
> and PR — and this role can create IAM and read `terraform.tfstate` (the cluster CA + any secrets in
> state). For anything beyond a solo throwaway test, split it: a **read-only plan role** (broad
> subject, used by `plan` on PRs) and a **privileged apply role** whose trust subject is pinned to
> `repo:<owner>/telosMUD-infra:ref:refs/heads/main` (or `:environment:production`). Never give a
> `:*`-trusted role IAM/admin rights in a repo with outside collaborators.

For the **SOPS** secret path (CI-applied encrypted secrets, optional): `age-keygen -o age.key` → copy
the `public key:` line into [.sops.yaml](.sops.yaml); store the file contents as the `SOPS_AGE_KEY`
Actions secret.

## 1. Provision the cluster (Terraform)

```sh
scripts/bootstrap-local.sh          # writes terraform.tfvars
cd terraform/envs/staging
terraform init
terraform apply                     # ~15-20 min: VPC, EKS control plane, node group, addons,
                                    # ingress-nginx + cert-manager (helm), gp3 SC, S3 backup bucket
```

Point `kubectl` at the new cluster and read the two NLB hostnames you need for DNS:

```sh
$(terraform output -raw configure_kubectl)          # aws eks update-kubeconfig --name telos-staging ...
kubectl get nodes                                    # one Ready node
kubectl -n telosmud get svc gate \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'; echo   # telnet NLB (once the app is deployed)
eval "$(terraform output -raw ingress_lb_hint)"; echo              # web/grafana ingress NLB hostname
```

> The gate NLB hostname only exists after the app is deployed (step 4). The ingress-nginx NLB exists
> right after `apply`.

## 2. Cluster add-ons

cert-manager and ingress-nginx are installed by `terraform/modules/cluster-bootstrap`. Apply the
Let's Encrypt ClusterIssuer once the cluster is up:

```sh
kubectl -n cert-manager rollout status deploy/cert-manager-webhook   # wait before applying the issuer
kubectl apply -f k8s/addons/letsencrypt-issuer.yaml                  # ClusterIssuer (HTTP-01 / nginx)
```

## 3. Secrets (out-of-band; the SOPS path is off by default)

No GHCR pull secret is needed — the `ghcr.io/double-nibble/*` images are public.

```sh
# Grafana refuses to start without an admin password (no default-cred Grafana):
kubectl -n telosmud create secret generic grafana-admin \
  --from-literal=admin-password="$(openssl rand -base64 24)"

# telos-secrets. Random tokens are `openssl rand -base64 32`. POSTGRES_PASSWORD must match the
# password embedded in TELOS_POSTGRES_DSN. The signing/handoff keys are Ed25519, base64-std
# (private = 64-byte key or 32-byte seed; public = 32-byte).
kubectl -n telosmud create secret generic telos-secrets \
  --from-literal=POSTGRES_PASSWORD=... \
  --from-literal=TELOS_POSTGRES_DSN='postgres://telos:...@postgres:5432/telosmud?sslmode=disable' \
  --from-literal=TELOS_WEB_SESSION_KEY=... --from-literal=TELOS_ACCOUNT_CALLER_TOKEN=... \
  --from-literal=TELOS_ACCOUNT_SIGNING_KEY=... --from-literal=TELOS_ACCOUNT_VERIFY_KEY=... \
  --from-literal=TELOS_HANDOFF_SIGNING_KEY=... --from-literal=TELOS_HANDOFF_VERIFY_KEY=... \
  --from-literal=TELOS_GITHUB_CLIENT_ID=PLACEHOLDER --from-literal=TELOS_GITHUB_CLIENT_SECRET=PLACEHOLDER
```

Staging can start with empty/placeholder GitHub OAuth values; real OAuth login works once they're set.
`TELOS_ACCOUNT_VERIFY_KEY` must be wired into the **world**, not just the account (the prod overlay
does this) — without it the shard silently skips session-assertion verification.

## 4. Deploy the app

```sh
# If you keep secrets under SOPS (optional): sops -d k8s/overlays/staging/secrets.enc.yaml | kubectl apply -f -
kubectl -n telosmud delete job db-init --ignore-not-found         # Jobs are immutable; re-run migrate+import
kustomize build k8s/overlays/staging | kubectl apply -f -
kubectl -n telosmud get pods -w
```

Order is handled by the manifests: `db-init` (migrate + content import) → world/gate/account. PVCs
(postgres, nats) bind on the default **gp3** StorageClass; they are AZ-locked, which is why the node
group is single-AZ.

## 5. DNS (CNAME the hosts at the NLB hostnames)

EKS load balancers hand out **DNS names, not static IPs**, so point each host at the NLB hostname with
a **CNAME** (in the `double-nibble.com` zone, managed outside this repo):

```
staging.telos.double-nibble.com          CNAME  <ingress-nginx NLB hostname>   # web / OAuth
grafana.staging.telos.double-nibble.com   CNAME  <ingress-nginx NLB hostname>   # grafana
# gate telnet host (if you want a name instead of the raw NLB hostname):
gate.staging.telos.double-nibble.com      CNAME  <gate NLB hostname>
```

cert-manager's HTTP-01 challenge and the `gate-tls` / `web-tls` certs all need the web host resolving,
so set DNS before (or immediately after) deploying, or the certs stay pending.

## 6. Verify end-to-end

```sh
# Telnet front door (staging keeps account-backed OAuth login; plaintext telnet):
telnet $(kubectl -n telosmud get svc gate -o jsonpath='{.status.loadBalancer.ingress[0].hostname}') 4000
# Web / OAuth:
curl -I https://staging.telos.double-nibble.com/
kubectl -n telosmud get certificate                       # web-tls (+ gate-tls in prod) -> READY True
```

## 7. Production bring-up

Production differs from staging: `terraform/envs/production` + `k8s/overlays/production`, TLS-only
gate, real GitHub OAuth app + domain, secure cookies, and a real handoff keypair instead of
`TELOS_ALLOW_INSECURE`.

### 7.1 Provision + kubeconfig

```sh
cd terraform/envs/production
terraform init && terraform apply
#   or in CI: gh workflow run terraform.yml -f env=production   # applies only from main; gated on the
#                                                                 # `production` GitHub Environment (manual approve)
$(terraform output -raw configure_kubectl)
```

### 7.2 DNS + the gate's DNS-01 cert (hard prerequisite for the TLS gate)

Production uses **two NLBs on two hostnames** — the gate (raw TCP) can't share ingress-nginx's HTTP
NLB. So there are two CNAMEs, and the gate's TLS cert is issued differently from the web cert:

```
telos.double-nibble.com        CNAME  <ingress-nginx NLB hostname>   # web / OAuth  (HTTP-01 cert)
gate.telos.double-nibble.com   CNAME  <gate NLB hostname>            # telnet / TLS (DNS-01 cert)
```

- **Web cert** (`web-tls`, host `telos.double-nibble.com`) → HTTP-01 through ingress-nginx. Works
  because that host resolves to the ingress NLB.
- **Gate cert** (`gate-tls`, host `gate.telos.double-nibble.com`) → **DNS-01** (Cloudflare), because
  that host resolves to the gate NLB, which has no HTTP listener for an HTTP-01 challenge. Wire the
  DNS-01 issuer once (production only):
  ```sh
  kubectl -n cert-manager create secret generic cloudflare-api-token --from-literal=api-token=<token>
  kubectl apply -f k8s/addons/letsencrypt-dns01.yaml
  ```

The prod gate is **TLS-only** and mounts the `gate-tls` Secret, so the gate pod stays in
`ContainerCreating` until that cert issues — set the DNS-01 issuer + the `gate.` CNAME before deploying.
Players then telnet-TLS to `gate.telos.double-nibble.com:4000`.

### 7.3 Add-ons + secrets

Same as §2–§3 against the production cluster. Create the prod GitHub OAuth app with callback
`https://telos.double-nibble.com/auth/github/callback`, then inject its credentials without putting the
secret in shell history:

```sh
kubectl -n telosmud patch secret telos-secrets --type=merge \
  -p '{"stringData":{"TELOS_GITHUB_CLIENT_ID":"...","TELOS_GITHUB_CLIENT_SECRET":"..."}}'
```

### 7.4 Deploy + verify

```sh
gh workflow run deploy.yml -f env=production   # manual-only for prod; staging auto-deploys on push
```

```sh
curl -I https://telos.double-nibble.com/                  # 200, Let's Encrypt cert
kubectl -n telosmud get certificate                       # gate-tls + web-tls -> READY True
kubectl -n telosmud logs deploy/world | grep -Ei 'verification|handoff|zones'
#   -> "session-assertion verification enabled (ed25519)", "cross-shard handoff ... (ed25519)"
# Verify the gate cert SAN actually matches the host players dial (catches a name/cert mismatch):
echo | openssl s_client -connect gate.telos.double-nibble.com:4000 \
  -servername gate.telos.double-nibble.com -verify_return_error 2>/dev/null \
  | openssl x509 -noout -subject -ext subjectAltName
```

## Observability (LGTM)

The `k8s/base/observability/` backends (Loki + Prometheus + Grafana) deploy via the normal
`kubectl apply -k` flow. Grafana is ClusterIP in base; the public hostname + basic-auth gate are the
staging overlay (`grafana-ingress-staging.yaml`).

**Grafana admin password (required before first deploy).** See §3.

**Retention & disk (the load-bearing part).** gp3 PVCs ARE size-bounded (unlike the old k3s
local-path), so a runaway Loki/Prometheus fills its OWN volume and goes read-only rather than taking
the node down — but that still loses observability, so retention is configured before first ingest:
Loki `compactor.retention_enabled: true` + 7d, Prometheus `--storage.tsdb.retention.time=7d` and
`.size=2GB`. The `NodeDiskFillingUp` alert fires at 80% node root-FS usage.

**Public Grafana (its own hostname behind ingress-nginx basic auth).** Two operator steps:

1. **DNS CNAME (required before the cert issues):** `grafana.staging.telos.double-nibble.com` → the
   ingress-nginx NLB hostname. Until it resolves the Ingress is live but `grafana-web-tls` stays pending.
2. **basic-auth Secret (created out-of-band, like `telos-secrets`).** ingress-nginx reads the htpasswd
   under the **`auth`** key (Traefik used `users`):
   ```sh
   kubectl -n telosmud create secret generic grafana-basic-auth \
     --from-literal=auth="$(htpasswd -nbB telos "$(openssl rand -base64 18)")"
   ```
   This is the independent second gate in front of Grafana's own login (Grafana has a 2025 pre-auth-CVE
   history). A missing Secret makes ingress-nginx fail-closed (503).

**Grafana version + upgrade cadence.** Pinned to `grafana/grafana:12.4.2`. Bump the pin on each Grafana
security release (grafana.com/security) and redeploy.

## Backups

The `pg-backup` CronJob (`k8s/base/pg-backup.yaml`) runs nightly at 03:17 UTC: an initContainer
`pg_dump -Fc`s the DB (via `TELOS_POSTGRES_DSN` from `telos-secrets`) into an in-memory scratch volume,
asserts it contains table data, then an `aws-cli` container uploads it to **S3** and shreds the local
copy. This is the only thing between a lost EBS volume and total data loss on this single-node topology.

**RPO:** a restore recovers to the last app→Postgres flush (durable shard memory can lead Postgres by
~60s), and nightly cadence means up to ~24h of loss worst-case — run an on-demand backup before risky ops.

**Bucket & credentials.** The bucket is provisioned by Terraform (`terraform output -raw backup_bucket`,
e.g. `telos-staging-backups-<account-id>`). Create a **dedicated, bucket-scoped IAM user** for backup
writes (NEVER a shared/admin key — this key lives in an in-cluster Secret) with a policy allowing
`s3:PutObject` on `arn:aws:s3:::<bucket>/*`, generate an access key, then create the `backup-s3` Secret
(jobs fail with "secret backup-s3 not found" until it exists — deliberate):

```sh
kubectl -n telosmud create secret generic backup-s3 \
  --from-literal=AWS_ACCESS_KEY_ID=<backup-writer-access-key> \
  --from-literal=AWS_SECRET_ACCESS_KEY=<backup-writer-secret-key> \
  --from-literal=AWS_DEFAULT_REGION=us-east-1 \
  --from-literal=BACKUP_BUCKET=<terraform backup_bucket output> \
  --from-literal=BACKUP_PREFIX=staging       # or `production`
```

> Follow-up: replace the static key with IRSA — bind the `pg-backup` ServiceAccount to an IAM role
> (via the cluster's OIDC provider) scoped to `s3:PutObject` on the bucket, and drop the Secret. The
> eks module already outputs `oidc_provider_arn` for this.

**Verify / run on demand:**

```sh
kubectl -n telosmud create job pg-backup-now --from=cronjob/pg-backup
kubectl -n telosmud logs -f job/pg-backup-now -c dump     # "dump contains N tables of data (… bytes)"
kubectl -n telosmud logs -f job/pg-backup-now -c upload   # "backup complete: s3://…/staging/…dump"
aws s3 ls "s3://$(cd terraform/envs/staging && terraform output -raw backup_bucket)/staging/"
```

**Restore.** The dump is custom-format (`pg_restore`, not `psql`). Stop writers, stage the file into
the pod, restore, bring the app back:

```sh
kubectl -n telosmud scale deploy/world deploy/account deploy/gate --replicas=0

aws s3 cp "s3://<bucket>/staging/telosmud-<ts>.dump" /tmp/restore.dump
kubectl -n telosmud cp /tmp/restore.dump postgres-0:/tmp/restore.dump -c postgres

# FULL restore (schema + goose bookkeeping + content + player state all from the dump — do NOT re-run
# db-init afterwards):
kubectl -n telosmud exec -i postgres-0 -c postgres -- \
  pg_restore --clean --if-exists --no-owner --exit-on-error -U telos -d telosmud /tmp/restore.dump

# — OR — SELECTIVE restore of just durable PLAYER STATE (let db-init re-derive content/definition tables):
kubectl -n telosmud exec -i postgres-0 -c postgres -- \
  pg_restore --data-only --no-owner --exit-on-error -U telos -d telosmud \
    -t accounts -t account_identities -t account_role_audit -t characters -t mail -t object_instances \
    /tmp/restore.dump

kubectl -n telosmud exec postgres-0 -c postgres -- rm -f /tmp/restore.dump
kubectl -n telosmud scale deploy/world deploy/account deploy/gate --replicas=<N>
```

Bucket versioning + a lifecycle expiry are set by Terraform (`backup_retention_days`, default 30).

## Teardown

Order matters: the load balancers and dynamically-provisioned EBS volumes are created by Kubernetes,
not Terraform, so remove them (and wait for AWS to finish) before `terraform destroy` or the VPC
delete hits `DependencyViolation` on lingering LB ENIs/security groups.

```sh
cd terraform/envs/staging

# 1. Delete the namespace — this removes the gate LoadBalancer Service (its NLB) AND the PVCs, whose
#    reclaimPolicy: Delete then deletes the backing EBS volumes (otherwise they orphan and keep costing).
kubectl delete ns telosmud --wait

# 2. Remove ingress-nginx (its NLB). Terraform's helm_release destroy also does this, but doing it
#    now lets both NLBs drain together.
helm -n ingress-nginx uninstall ingress-nginx || true

# 3. WAIT for the NLBs + their ENIs to actually disappear (async, ~minutes) before destroying the VPC:
aws elbv2 describe-load-balancers --query "LoadBalancers[?VpcId=='$(terraform output -raw vpc_id 2>/dev/null)'].LoadBalancerName" --output text
#    (repeat until empty; the backup bucket is emptied automatically by force_destroy)

terraform destroy
```
