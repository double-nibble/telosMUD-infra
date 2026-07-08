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

## 6. Production differences

- Use `terraform/envs/production` and `k8s/overlays/production`.
- No `TELOS_DEV_AUTOAUTH`; TLS-only gate; real GitHub OAuth app + domain; secure cookies.
- Confirm the single-node handoff-guard question in PLAN.md before dropping `TELOS_ALLOW_INSECURE`.

## Backups

The `pg-backup` CronJob runs `pg_dump` to OCI Object Storage nightly. Restore by piping a dump
into the `postgres` pod's `psql`.

## Teardown

```sh
cd terraform/envs/staging && terraform destroy
```
