# TelosMUD deploy runbook

Step-by-step bring-up of a fresh environment. Do `staging` first, then `production`.
See [PLAN.md](PLAN.md) for the design and rationale.

## 0. Prerequisites (one-time)

- An **Oracle Cloud** account (free tier is enough). Note your **tenancy OCID**, create a
  **compartment** for TelosMUD, and generate an **API signing key** (User → API Keys).
- Install locally: `terraform`, `oci` CLI, `kubectl`, `kustomize`, `sops`, `age`.
- Generate the SOPS key: `age-keygen -o age.key` → copy the `public key:` line into
  [.sops.yaml](.sops.yaml). Store the file's contents as the `SOPS_AGE_KEY` GitHub Actions
  secret in this repo.
- Create an **OCI Object Storage bucket** for Terraform state; put its name/namespace in the
  `backend.tf` of each env.
- Create an SSH keypair for the VMs; upload the public key path into the env `*.tfvars`.
- In the `gomud` repo, ensure images publish **arm64** to GHCR (`docker buildx --platform linux/arm64`).

## 1. Provision the cluster (Terraform)

```sh
cd terraform/envs/staging
# Fill in terraform.tfvars: tenancy/compartment OCIDs, region, ssh_public_key_path, etc.
terraform init
terraform apply
```

Terraform creates the VCN + security list, the A1 VM (cloud-init installs k3s), and writes a
kubeconfig. If you hit **`Out of host capacity`**, change `region`/availability domain and
re-apply — A1 free capacity is intermittent.

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
