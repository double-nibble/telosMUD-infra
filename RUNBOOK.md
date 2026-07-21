# TelosMUD deploy runbook

Step-by-step bring-up of a fresh environment. Do `staging` first, then `production`.
See [PLAN.md](PLAN.md) for the design and rationale.

## 0. Prerequisites (one-time)

- An **Oracle Cloud** account (free tier is enough) with a **compartment** for TelosMUD.
- Configure the **`oci` CLI**: `oci setup config` (creates `~/.oci/config` + an API signing key).
  This is the ONLY per-collaborator setup — everything else is discovered.
- Install locally: `terraform`, `oci` CLI, `kubectl`, `kustomize`, `sops`, `age`.

### Bootstrap your local config (idempotent)

Instead of hand-copying OCIDs between machines, run:

```sh
scripts/bootstrap-local.sh
```

It reads your configured `oci` CLI and writes the gitignored
`terraform/envs/{staging,production}/terraform.tfvars` (tenancy, region, compartment,
availability domain, object-storage namespace, newest Ubuntu 22.04 arm64 image OCID) and
creates `~/.ssh/telos_id_ed25519` if missing. No secrets are involved — Terraform auth comes
from `~/.oci/config`. Override the compartment name with `TELOS_COMPARTMENT=<name>` (default
`telosmud`, matched case-insensitively) or the AD with `TELOS_AD=<name>`.

For the **SOPS** secret path (needed only for CI or encrypted secrets): `age-keygen -o age.key`
→ copy the `public key:` line into [.sops.yaml](.sops.yaml); store the file contents as the
`SOPS_AGE_KEY` GitHub Actions secret. For **remote Terraform state**, create an OCI Object
Storage bucket and a Customer Secret Key (the `backend.tf` endpoint/namespace is pre-filled).

## 1. Provision the cluster (Terraform)

```sh
scripts/bootstrap-local.sh        # writes terraform.tfvars + ssh key
cd terraform/envs/staging
# First run: comment out the backend "s3" block in backend.tf to use local state.
terraform init
terraform apply                   # "Out of host capacity"? try TELOS_AD=...-2, re-run bootstrap, retry
```

Terraform creates the VCN + security list, the A1 VM (cloud-init installs k3s), and writes a
kubeconfig. If you hit **`Out of host capacity`**, change `region`/availability domain and
re-apply — A1 free capacity is intermittent.

### "Out of host capacity" (Always-Free A1)

A1 (Ampere) free capacity is chronically scarce in busy regions and frees up in short windows.
Mitigations, most effective first:

1. **Upgrade the tenancy to Pay-As-You-Go.** Free-only accounts are deprioritized for A1
   capacity; PAYG accounts get it almost immediately. **Always-Free A1 usage is still unbilled**,
   so you stay at $0 (a card is required on file, not charged for the free shape).
2. **Run the retry loop** — sweeps every AD and keeps trying until a host frees up:
   ```sh
   scripts/apply-with-retry.sh staging
   # try a smaller (more findable) shape:
   OCPUS=1 MEMORY_GBS=6 scripts/apply-with-retry.sh staging
   ```
   It only retries on capacity errors; any real error aborts. Partial state is fine — the
   network is already created, so it just adds the instance.
3. **Try a less-contended region.** Re-run `scripts/bootstrap-local.sh` after subscribing to a
   quieter region (Ashburn/Phoenix are the busiest); the image OCID is re-discovered per region.

Fetch the kubeconfig (also produced by the `k3s` module output):

```sh
terraform output -raw kubeconfig > ~/.kube/telos-staging.kubeconfig
export KUBECONFIG=~/.kube/telos-staging.kubeconfig
kubectl get nodes         # should show one Ready node
```

Store that kubeconfig as this repo's `KUBECONFIG_STAGING` Actions secret (base64) for CI deploys.

## 2. Cluster add-ons

```sh
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/latest/download/cert-manager.yaml
# Then create the Cloudflare DNS-01 ClusterIssuer (token in a SOPS secret). See k8s/base/README.
```

## 3. Secrets

```sh
# Edit the decrypted secret, then re-encrypt in place:
sops k8s/overlays/staging/secrets.enc.yaml
```

Populate: `POSTGRES_PASSWORD`, `TELOS_WEB_SESSION_KEY`, `TELOS_ACCOUNT_CALLER_TOKEN`,
account signing/verify keypair, and (prod) `TELOS_GITHUB_CLIENT_ID/SECRET`. The GHCR pull
secret is created from a PAT (see below).

```sh
kubectl create secret docker-registry ghcr \
  --docker-server=ghcr.io --docker-username=<gh-user> --docker-password=<ghcr-pat> \
  -n telosmud
```

## 4. Deploy the app

```sh
sops -d k8s/overlays/staging/secrets.enc.yaml | kubectl apply -f -
kustomize build k8s/overlays/staging | kubectl apply -f -
kubectl -n telosmud get pods -w
```

Order is handled by the manifests: `migrate` (Job) → `seed` (Job) → world/gate/account.

## 5. Verify end-to-end

```sh
# Telnet front door (staging keeps dev-autoauth: just type a name):
telnet <node-public-ip> 4000
# Web / OAuth (prod):
curl -I https://staging.<domain>/
```

## 6. Production bring-up (full walkthrough)

Production differs from staging: `terraform/envs/production` + `k8s/overlays/production`, no
`TELOS_DEV_AUTOAUTH` (compiled out of release images anyway), TLS-only gate, real GitHub OAuth app +
domain, secure cookies, and a real handoff keypair instead of `TELOS_ALLOW_INSECURE`. Do staging
first; this section is the exact order that worked, including the traps.

> This was walked through end-to-end on 2026-07-21 to bring up `telos.double-nibble.com`. The steps
> below are what actually happened, not an idealized plan.

### 6.1 Provision the cluster

```sh
# Locally (sweeps ADs on capacity errors), or in CI:
scripts/apply-with-retry.sh production
#   gh workflow run terraform.yml -f env=production   # applies only from main; gated on the
#                                                       # `production` GitHub Environment (manual approve)
```

Then capture the two outputs you need everywhere else:

```sh
cd terraform/envs/production
terraform output -raw public_ip     # the RESERVED IP — your DNS target
terraform output -raw kubeconfig > ./kubeconfig   # server is the fqdn, not the IP
```

### 6.2 If the apply hangs or you cancel it mid-run (recovery)

A first apply can wedge for 10+ minutes on the k3s provisioner. The historical cause was a
**cloud-init DNS race**: the instance has no ephemeral public IP, so the reserved IP (which provides
egress) attaches a few seconds *after* boot — early-boot DNS fails, the k3s installer's binary
download (`update.k3s.io`/`github.com`) fails, k3s never installs, and cloud-init spins forever in
its final `until kubectl get nodes` loop, so `cloud-init status --wait` (the Terraform provisioner)
never returns. `terraform/modules/compute` now gates on DNS + retries the install under a deadline,
so a fresh apply should not hit this. If you inherit a wedged/partial apply anyway:

```sh
# 1. Is the VM actually up but k3s-less? (SSH works even when the provisioner is stuck)
ssh -i ~/.ssh/telos_id_ed25519 ubuntu@<reserved-ip> \
  'sudo cloud-init status; sudo systemctl is-active k3s; ls /etc/rancher/k3s/k3s.yaml'

# 2. If k3s never installed (old image / DNS race), finish it by hand — DNS is up now.
#    The wedged cloud-init loop self-completes once k3s is active, flipping status to `done`.
ssh -i ~/.ssh/telos_id_ed25519 ubuntu@<reserved-ip> \
  'sudo env INSTALL_K3S_EXEC="server --tls-san <fqdn> --write-kubeconfig-mode 644" sh /tmp/install-k3s.sh'

# 3. A cancelled apply can persist the VM to state but leave the RESERVED IP orphaned (created in
#    OCI, absent from state). Re-import it so the next apply adopts it instead of trying to recreate
#    (which fails: the private IP already has an association):
terraform import module.compute.oci_core_public_ip.reserved <publicip-ocid>
#    If this errors on `data.local_file.kubeconfig` (open ./kubeconfig: no such file), the local
#    kubeconfig the module reads is missing — seed it first, then re-run the import:
ssh -i ~/.ssh/telos_id_ed25519 ubuntu@<reserved-ip> 'sudo cat /etc/rancher/k3s/k3s.yaml' \
  | sed 's/127.0.0.1/<fqdn>/' > ./kubeconfig
```

Find the public-IP OCID with `oci network public-ip list --compartment-id <ocid> --scope REGION --all`.

### 6.3 DNS — do this BEFORE deploying (hard prerequisite)

```
<fqdn>   A   <reserved-ip>
```

Nothing TLS works until this resolves: cert-manager's HTTP-01 challenge, the `gate-tls` cert the
gate pod mounts, and the domain kubeconfig all need it. **The gate pod stays in `ContainerCreating`
until `gate-tls` issues**, which can't happen without DNS — so deploying before DNS is set gives you
a stuck rollout.

### 6.4 Cluster add-ons

```sh
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/latest/download/cert-manager.yaml
kubectl -n cert-manager rollout status deploy/cert-manager-webhook   # wait before the next step
kubectl apply -f k8s/addons/letsencrypt-issuer.yaml                  # ClusterIssuer (HTTP-01/Traefik)
```

### 6.5 Secrets (out-of-band; the SOPS path is off by default)

```sh
# CI needs the cluster kubeconfig to deploy:
base64 -i terraform/envs/production/kubeconfig | gh secret set KUBECONFIG_PRODUCTION

# Grafana refuses to start without an admin password (no default-cred Grafana):
kubectl -n telosmud create secret generic grafana-admin \
  --from-literal=admin-password="$(openssl rand -base64 24)"

# telos-secrets. Random tokens are `openssl rand -base64 32`. POSTGRES_PASSWORD must match the
# password embedded in TELOS_POSTGRES_DSN. The signing/handoff keys are Ed25519, base64-std
# (private = 64-byte key or 32-byte seed; public = 32-byte). Generate a matching pair with:
#   go run - <<'EOF'  # prints "<b64-priv> <b64-pub>"
#   package main
#   import ("crypto/ed25519";"crypto/rand";"encoding/base64";"fmt")
#   func main(){pub,priv,_:=ed25519.GenerateKey(rand.Reader);e:=base64.StdEncoding.EncodeToString
#   fmt.Println(e(priv),e(pub))}
#   EOF
kubectl -n telosmud create secret generic telos-secrets \
  --from-literal=POSTGRES_PASSWORD=... \
  --from-literal=TELOS_POSTGRES_DSN='postgres://telos:...@postgres:5432/telosmud?sslmode=disable' \
  --from-literal=TELOS_WEB_SESSION_KEY=... --from-literal=TELOS_ACCOUNT_CALLER_TOKEN=... \
  --from-literal=TELOS_ACCOUNT_SIGNING_KEY=... --from-literal=TELOS_ACCOUNT_VERIFY_KEY=... \
  --from-literal=TELOS_HANDOFF_SIGNING_KEY=... --from-literal=TELOS_HANDOFF_VERIFY_KEY=... \
  --from-literal=TELOS_GITHUB_CLIENT_ID=PLACEHOLDER --from-literal=TELOS_GITHUB_CLIENT_SECRET=PLACEHOLDER
```

Two easy-to-miss points:

- **`TELOS_ACCOUNT_VERIFY_KEY` must be wired into the WORLD, not just the account** (the prod overlay
  does this). Without the verify key the shard's `verifyKey` is nil and it **silently skips
  session-assertion verification** — trusting the gate's asserted identity blindly and never applying
  builder/admin tier or instanced-zone minting. `session-assertion verification enabled (ed25519)` in
  the world log is the proof it's on.
- **No GHCR pull secret is needed** — the `ghcr.io/double-nibble/*` packages are public, so the
  `imagePullSecrets: [ghcr]` reference in `base/rbac.yaml` is simply ignored.

**GitHub OAuth app (prod-specific — staging's can't be reused):** create an OAuth app with callback
`https://<fqdn>/auth/github/callback`, then inject the credentials **without putting the secret in a
shell history / chat** by patching the placeholders:

```sh
kubectl -n telosmud patch secret telos-secrets --type=merge \
  -p '{"stringData":{"TELOS_GITHUB_CLIENT_ID":"...","TELOS_GITHUB_CLIENT_SECRET":"..."}}'
```

### 6.6 Deploy

```sh
gh workflow run deploy.yml -f env=production   # manual-only for prod; staging auto-deploys on push
```

The workflow recreates `db-init` (migrate + content import), then waits on the world/gate/account
rollouts. Order is handled by the manifests.

### 6.7 Verify end-to-end

```sh
curl -I https://<fqdn>/                                   # 200, Let's Encrypt cert
kubectl -n telosmud get certificate                       # gate-tls + web-tls -> READY True
kubectl -n telosmud logs deploy/account | grep oauth      # "oauth broker listening" ... "oauth":true
kubectl -n telosmud logs deploy/world | grep -Ei 'verification|handoff|zones'
#   -> "session-assertion verification enabled (ed25519)", "cross-shard handoff ... (ed25519)",
#      "content loaded ... zones:N"
echo | openssl s_client -connect <fqdn>:4000 -servername <fqdn> 2>/dev/null | openssl x509 -noout -subject
```

### 6.8 Known cosmetics / follow-ups

- Services log `"env":"dev"` in prod. It is **cosmetic** — the insecure allowance is gated on
  `TELOS_ALLOW_INSECURE` (never `cfg.Env`) and dev-autoauth is compiled out of release images. Set
  `TELOS_ENV=production` in the overlay if you want the label to match.
- The out-of-band Secrets (`telos-secrets`, `grafana-admin`) live only in the cluster. For durability
  and disaster recovery, move them under SOPS + git (see `.sops.yaml` / §3) once the box is stable.
- Confirm the single-node handoff-guard reasoning in PLAN.md — resolved for a Redis-backed shard: it
  supplies a real handoff keypair, so it boots with authenticated handoffs and `AllowInsecure=false`.

## Observability (LGTM)

The `k8s/base/observability/` backends (Loki + Prometheus + Grafana; Tempo is deferred to the tracing
milestone) are deployed by the normal `kubectl apply -k` flow. Grafana is ClusterIP here — its public
hostname + Traefik auth middleware are a separate change.

**Grafana admin password (required before first deploy).** Grafana reads its admin password from the
`grafana-admin` Secret; a missing Secret makes the pod fail to start (deliberate — no default-cred
Grafana). Staging's SOPS path is off, so create it out-of-band once, like `telos-secrets`:

```sh
kubectl -n telosmud create secret generic grafana-admin \
  --from-literal=admin-password="$(openssl rand -base64 24)"
# Retrieve it to log in / rotate:
kubectl -n telosmud get secret grafana-admin -o jsonpath='{.data.admin-password}' | base64 -d; echo
```

**Retention & disk (the load-bearing part).** local-path PVCs do NOT enforce their requested size —
they are directories on the 50 GB node root FS, so an unbounded Loki/Prometheus fills `/` and takes the
whole game stack down. Retention is therefore configured before first ingest: Loki
`compactor.retention_enabled: true` + 7d, Prometheus `--storage.tsdb.retention.time=7d` **and**
`.size=2GB` (size retention is what saves you during a cardinality blowup). The observability PVC budget
is ~7Gi (Loki 3Gi + Prometheus 3Gi + Grafana 1Gi); with the existing 15Gi (postgres+nats) that is ~22Gi
of ~45Gi free — **the boot volume is deliberately NOT raised** (verified 45 GB free; raising it is a
Terraform change that risks an instance rebuild for no need). The `NodeDiskFillingUp` Prometheus alert
fires at 80% root-FS usage once the collector's hostmetrics feed lands.

**Storage-at-rest note.** On single-node k3s the Loki/Grafana data sits on the node boot volume, so any
volume snapshot is a PII export once logs ship — factor that into backup handling.

**Collector host mount (prod decision).** The log/metric collector DaemonSet mounts the node `/`
read-only for hostmetrics. It cannot write host files, but a collector RCE could *read* every root-owned
file on the node, including other pods' secret volumes. Accepted on single-node staging; before prod,
either accept it explicitly or source root-FS usage from node-exporter and drop the `/` mount.

**Public Grafana (its own hostname behind Traefik basicAuth).** Two operator steps:

1. **DNS A record (required before the cert issues):**
   `grafana.staging.telos.double-nibble.com` → the node's reserved public IP, in the `double-nibble.com`
   zone (managed outside this repo). cert-manager's HTTP-01 challenge and the hostname both need it; until
   it exists the Ingress is live but `grafana-web-tls` stays pending.
2. **basicAuth Secret (created out-of-band, like `telos-secrets`):**
   ```sh
   kubectl -n telosmud create secret generic grafana-basic-auth \
     --from-literal=users="$(htpasswd -nbB telos "$(openssl rand -base64 18)")"
   ```
   This is the independent second gate in front of Grafana's own login (Grafana has a 2025 pre-auth-CVE
   history — the middleware is the point). A missing Secret makes Traefik fail-closed (deny).

**Grafana version + upgrade cadence.** Pinned to `grafana/grafana:12.4.2` — past the 2025 CVE-4123/6023/3260
chain AND the 2026 CVE-2026-27876 critical RCE (SQL-expressions arbitrary file write; patched 12.1.10/
12.4.2). An unattended Grafana on a public hostname is the mass-scan target profile — **bump the pin on
each Grafana security release** (grafana.com/security) and redeploy; the pod restart is zero-downtime for
a single-user staging box. This pin was already behind a critical RCE at the time it went public — treat
the cadence as load-bearing, not aspirational.

## Backups

The `pg-backup` CronJob (`k8s/base/pg-backup.yaml`) runs nightly at 03:17 UTC: an initContainer
`pg_dump -Fc`s the DB (via `TELOS_POSTGRES_DSN` from `telos-secrets`) into an in-memory scratch
volume, asserts it actually contains table data, then an `aws-cli` container uploads it to OCI
Object Storage (S3-compatible) and shreds the local copy. This is the ONLY thing between a wiped
boot volume and total data loss on this single-node/local-PVC topology.

**RPO:** a restore recovers to the *last app→Postgres flush*, not the last player action — the
durability ladder lets authoritative shard memory lead Postgres by up to the checkpoint interval
(~60s), plus explicit flushes on logout/drain. Nightly cadence means up to ~24h of loss in the
worst case; run an on-demand backup (below) before risky operations.

**Buckets & credentials (least-privilege — do NOT reuse the tfstate key):**

```sh
# 1. Create the backup bucket(s) ONCE, out-of-band (like the tfstate bucket). PREFER one bucket per
#    env so a staging-cluster credential leak can't read/tamper PRODUCTION dumps (a shared bucket +
#    BACKUP_PREFIX is only a naming convention, not an authz boundary):
oci os bucket create -ns <namespace> --compartment-id <compartment-ocid> --name telosmud-backups-production
oci os bucket get -ns <namespace> --name telosmud-backups-production --query 'data."public-access-type"'
#    ^ MUST print "NoPublicAccess" (the default) — these dumps are a full accounts/PII export.

# 2. Create a DEDICATED, bucket-scoped IAM user for backup writes — NEVER the Terraform-state
#    Customer Secret Key (that key inherits its user's FULL permissions; a leak of this in-cluster
#    Secret would then expose tfstate = every Terraform-managed secret in plaintext). Console:
#    create user `telosmud-backup-writer` in a group `backup-writers`, add the policy, then generate
#    a Customer Secret Key for that user:
#      allow group backup-writers to manage objects in compartment <name> where target.bucket.name='telosmud-backups-production'
#      allow group backup-writers to read  buckets in compartment <name> where target.bucket.name='telosmud-backups-production'
#    (Give each env's cluster only its own bucket's key.)

# 3. Create the `backup-s3` Secret in each cluster (jobs fail with "secret backup-s3 not found" until
#    this exists — deliberate, so it never silently backs up to nowhere):
kubectl -n telosmud create secret generic backup-s3 \
  --from-literal=AWS_ACCESS_KEY_ID=<backup-writer-access-key> \
  --from-literal=AWS_SECRET_ACCESS_KEY=<backup-writer-secret-key> \
  --from-literal=BACKUP_BUCKET=telosmud-backups-production \
  --from-literal=BACKUP_S3_ENDPOINT=https://<namespace>.compat.objectstorage.<region>.oraclecloud.com \
  --from-literal=BACKUP_PREFIX=production   # or `staging`, into that env's own bucket
```

**Verify / run on demand:**

```sh
kubectl -n telosmud create job pg-backup-now --from=cronjob/pg-backup
kubectl -n telosmud logs -f job/pg-backup-now -c dump     # "dump contains N tables of data (… bytes)"
kubectl -n telosmud logs -f job/pg-backup-now -c upload   # "backup complete: s3://…/production/…dump"
oci os object list -ns <namespace> --bucket-name telosmud-backups-production --prefix production
```

**Restore.** The dump is custom-format, so restore with `pg_restore` (NOT `psql`). `pg_restore` must
read a real file (it seeks the archive TOC — you can't stream it over stdin), so stage it into the
pod. `--clean --if-exists` drops+recreates each object, so this works onto the already-migrated DB
without a `DROP DATABASE` dance; `--exit-on-error` fails fast instead of a silent partial restore.
**Stop writers first** so the DB is idle:

```sh
kubectl -n telosmud scale deploy/world deploy/account deploy/gate --replicas=0

oci os object get -ns <namespace> --bucket-name telosmud-backups-production \
  --name production/telosmud-<ts>.dump --file /tmp/restore.dump
kubectl -n telosmud cp /tmp/restore.dump postgres-0:/tmp/restore.dump -c postgres

# FULL restore (schema + goose bookkeeping + content + player state all come from the dump —
# do NOT re-run db-init afterwards, it would double up):
kubectl -n telosmud exec -i postgres-0 -c postgres -- \
  pg_restore --clean --if-exists --no-owner --exit-on-error -U telos -d telosmud /tmp/restore.dump

# — OR — SELECTIVE restore of just the durable PLAYER STATE, letting db-init re-derive the
# reproducible content/definition tables from the external content store (the DR path you usually
# want after content already redeployed):
kubectl -n telosmud exec -i postgres-0 -c postgres -- \
  pg_restore --data-only --no-owner --exit-on-error -U telos -d telosmud \
    -t accounts -t account_identities -t account_role_audit -t characters -t mail -t object_instances \
    /tmp/restore.dump

kubectl -n telosmud exec postgres-0 -c postgres -- rm -f /tmp/restore.dump
kubectl -n telosmud scale deploy/world deploy/account deploy/gate --replicas=<N>   # bring the app back
```

**Retention (optional, requires one IAM grant).** A 14-day object-expiry lifecycle rule keeps the
bucket bounded, but OCI rejects `put-object-lifecycle-policy` (`InsufficientServicePermissions`)
until you grant the Object Storage service principal access to the bucket:

```
# IAM policy statement (Console -> Policies), then apply the lifecycle rule:
allow service objectstorage-<region> to manage object-family in compartment <name> where target.bucket.name='telosmud-backups-production'
oci os object-lifecycle-policy put -ns <namespace> --bucket-name telosmud-backups-production --from-json '{"items":[{"name":"expire-old-backups","action":"DELETE","timeAmount":14,"timeUnit":"DAYS","isEnabled":true,"target":"objects"}]}'
```

> Notes. The dump waits (`pg_isready` poll) for postgres to be reachable before dumping — on k3s the
> bundled kube-router netpol programs the `allow-postgres` rule for a new pod's IP a beat after start,
> so an immediate connect is REJECTed. The dump is memory-backed and shredded post-upload so a full-PII
> export never persists on the node boot disk (which the observability collector mounts read-only). A
> managed/off-node Postgres would remove the single-node-loss exposure entirely (bigger design
> question — tracked in issue #25).

## Teardown

```sh
cd terraform/envs/staging && terraform destroy
```
