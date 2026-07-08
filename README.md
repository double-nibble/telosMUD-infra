# telosMUD-infra

Infrastructure-as-code for deploying [TelosMUD](../gomud) to real clusters.

Two environments, each a single-node **k3s** cluster on an **Oracle Cloud Always-Free**
ARM VM. Everything runs in-cluster (Postgres, Redis, NATS, and the Telos services) so the
whole thing costs **$0** — no managed databases, no paid cloud load balancer.

- **Terraform** (`terraform/`) provisions the VM, network, and k3s. State lives in an OCI
  Object Storage bucket.
- **Kustomize** (`k8s/`) deploys the app: a `base/` plus per-environment overlays that flip
  the dev/prod hardening deltas.
- **GitHub Actions** (`.github/workflows/`) run `terraform apply` and `kubectl apply`.

Start with [PLAN.md](PLAN.md) for the design and cost model, then [RUNBOOK.md](RUNBOOK.md)
for the step-by-step bring-up.

## Layout

```
terraform/
  modules/{network,compute,k3s}/   # VCN + firewall, A1 instance, k3s + kubeconfig
  envs/{staging,production}/        # backend + tfvars per environment
k8s/
  base/                            # world, gate, account, postgres, redis, nats, jobs
  overlays/{staging,production}/   # env deltas (insecure flags, TLS, secrets, replicas)
.github/workflows/                 # terraform.yml, deploy.yml
scripts/                           # helper scripts (kubeconfig fetch, bootstrap)
```

## Status

First-pass scaffold. Values that require your OCI tenancy (compartment/tenancy OCIDs,
region, SSH key) and your domain are marked `# TODO` in the tfvars and overlay files.
