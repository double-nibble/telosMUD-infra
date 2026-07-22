# TelosMUD deployment plan

A two-environment (staging + production) Kubernetes deployment on **AWS EKS** for a low-traffic
(2–3 concurrent users) proof-of-concept. Not free — a paid, managed control plane and cloud load
balancers — chosen for operational simplicity over the previous Oracle Always-Free / k3s design.

## Decisions (settled)

| Decision | Choice | Why |
|---|---|---|
| Provider | **AWS** | Managed, familiar, no Always-Free capacity roulette. Cost is accepted. |
| Kubernetes | **EKS** (one managed cluster per env) | Managed control plane; no self-hosted k3s to babysit. |
| Nodes | **One managed node group, single node, single AZ** | Mirrors the old single-box topology; EBS is AZ-locked so pod + volume must share an AZ. |
| Node arch | **Graviton (arm64), `t4g.large`** | The GHCR images are multi-arch; arm64 is cheaper. `t4g.xlarge` if the LGTM stack is memory-tight. |
| IaC | **Terraform (AWS + helm + kubernetes providers)** | VPC/EKS via the community modules; ingress-nginx + cert-manager via helm. State in S3 + DynamoDB. |
| App delivery | **GitHub Actions + Kustomize** | `kustomize build overlays/<env> \| kubectl apply`. CI auth is keyless (GitHub OIDC → IAM role). |
| Telnet front door | **NLB** (`gate` Service `type: LoadBalancer` + nlb annotation) | An L4 Network Load Balancer forwards raw TCP untouched — the one thing an ALB / HTTP ingress can't do. |
| Web / OAuth + TLS | **ingress-nginx + cert-manager (Let's Encrypt, HTTP-01)** | Portable; the same LE issuer also mints the gate's telnet-TLS cert, which mounts into the gate pod. |
| Storage | **gp3 EBS via the EBS CSI driver** | Real size-enforced block volumes (default `gp3` StorageClass); AZ-locked. |
| World topology | **Single-shard** (all zones, one world) | No cross-shard handoff coordinator. Mirrors `docker-compose.single.yml`. |
| Images | **multi-arch, GHCR** | `ghcr.io/double-nibble/telos-*` already build `linux/amd64,linux/arm64`. |

## Why these shapes

The single design-defining constraint is that **`telos-gate` is a raw TCP telnet listener.** That
rules out ALB / API Gateway / any HTTP-only ingress for the front door. On k3s, Klipper `servicelb`
bound the port on the node IP for free; on EKS the equivalent is a **Network Load Balancer** (L4),
which the in-tree AWS cloud provider provisions from a plain `Service type: LoadBalancer` + the NLB
annotation — no AWS Load Balancer Controller required. Web/OAuth is ordinary HTTP, so it rides a
second NLB fronting **ingress-nginx**.

cert-manager stays (rather than ACM) because the gate needs a real cert **file** mounted for telnet
TLS — ACM terminates at the LB and can't hand a cert to a pod. One Let's Encrypt ClusterIssuer serves
both the web Ingress and the gate's `Certificate`.

**Single-AZ, single-node** is deliberate: the single-replica StatefulSets (postgres, nats) use
AZ-locked EBS volumes, so the node group is pinned to one subnet/AZ to keep pod and volume together.

## Resource budget (per env)

| | Value |
|---|---|
| Control plane | EKS managed (one per env) |
| Node | 1× `t4g.large` (2 vCPU / 8 GB) Graviton, single AZ; `t4g.xlarge` (16 GB) if the LGTM stack OOMs |
| Storage | gp3 EBS PVCs: postgres 10Gi + nats 5Gi + Loki 3Gi + Prometheus 3Gi + Grafana 1Gi |
| Load balancers | 2 NLBs (gate telnet :4000, ingress-nginx web :443/:80) |
| Networking | VPC, 2 AZs, single NAT gateway |
| Backups | S3 bucket (versioned, lifecycle-expired) |

## Cost model (rough, both envs, on-demand, us-east-1)

~$250–350/mo: 2× EKS control plane (~$146), 2× node, 4× NLB, 2× NAT gateway, EBS + S3 minimal. Levers:
single NAT per env (default), and `terraform destroy` per env when you're done testing. This is a
throwaway test deployment — not a $0 design.

## Per-cluster architecture

```
                 Internet
        ┌───────────┴────────────┐
  telnet:4000/tls           web:443 / :80
    NLB (gate Service)        NLB (ingress-nginx)
        │                         │
        ▼                         ▼  Ingress -> account (web :8080)
   telos-gate                     └─ Ingress -> grafana :3000 (basic auth)
        │
   ┌────┴──────────────── EKS cluster (1 node, 1 AZ) ─────────────────┐
   │  telos-world (:9090, single shard, all zones)                    │
   │  telos-account (:9100 gRPC + :8080 web)                          │
   │  postgres / nats  (StatefulSets, gp3 EBS)  |  redis (ephemeral)  │
   │  db-init (migrate + content import) + pg-backup (CronJob → S3)   │
   │  LGTM: loki / prometheus / grafana / otel-collector (DaemonSet)  │
   │  addons: EBS CSI, ingress-nginx, cert-manager (Let's Encrypt)    │
   └──────────────────────────────────────────────────────────────────┘
```

## Prod hardening deltas (base → production overlay)

| Setting | dev/staging | production |
|---|---|---|
| `TELOS_ALLOW_INSECURE` | `1` | unset (real `TELOS_HANDOFF_*` keypair instead) |
| `TELOS_GATE_ALLOW_PLAINTEXT` | `1` | unset (TLS-only via `TELOS_GATE_TLS_LISTEN/CERT/KEY`) |
| `TELOS_ACCOUNT_CALLER_TOKEN` | unset | set (gRPC caller auth) |
| `TELOS_ACCOUNT_SIGNING_KEY` / `_VERIFY_KEY` | unset | set (signed session assertions; verify key also on the world) |
| `TELOS_WEB_SECURE_COOKIES` | `0` | `1` |
| `TELOS_WEB_PUBLIC_URL` | `https://staging.<domain>` | `https://<domain>` |
| GitHub OAuth app | staging app | prod app (real callback URL) |
| Postgres password | dev | strong random secret |

## Secrets

The cluster Secrets (`telos-secrets`, `grafana-admin`) are created by the deploy workflow from GitHub
Actions secrets — no manual `kubectl`. DNS + cert secrets don't exist at all: external-dns and
cert-manager reach Route53 via **IRSA** roles, and cert-manager mints the TLS certs.

## CI/CD (one-click lifecycle)

- **`gomud` (app repo)** — publishes multi-arch (`amd64` + `arm64`) images to GHCR. No change here.
- **`telosMUD-infra` (this repo)**:
  - **`up.yml`** — `workflow_dispatch`: `terraform apply` → calls `deploy.yml`. Builds a whole env.
  - **`down.yml`** — `workflow_dispatch` (type `DESTROY`): drains the k8s NLBs + EBS, then
    `terraform destroy`.
  - `deploy.yml` — OIDC → `update-kubeconfig` → create Secrets from GH secrets → apply ClusterIssuers →
    `kustomize build | kubectl apply` → wait. Reusable (`workflow_call`) + push/dispatch.
  - `terraform.yml` — `plan` on PR, `apply` staging on push, production via dispatch. `validate.yml` —
    renders every overlay + `kubeconform`. All keyless via GitHub OIDC; Environments gate production.

## Terraform state

An **S3 bucket** (`telosmud-tfstate`, one key per env) with **native S3 state locking**
(`use_lockfile`, Terraform ≥1.11 — no DynamoDB table). Created once, out of band, before the first
`terraform init` (RUNBOOK §0).

## Domain & TLS (fully automated, per-env isolated)

A registered domain is the only unavoidable cost besides AWS, and it's the only DNS thing you set up:
a **root Route53 zone** (`double-nibble.com`). Everything else is automatic and **isolated per env** —
each env's `up` creates its **own subzone** (`staging.telos.…` / `telos.…`), delegates it from the root
(NS record), and scopes that env's external-dns + cert-manager **IRSA to only its own subzone**. So a
compromised staging DNS/cert pod cannot touch production names (Route53 IAM can't scope below a zone,
hence separate zones). `down` deletes the subzone + delegation.

EKS LBs hand out **DNS names, not IPs**, and the gate (raw TCP) and web (HTTP) sit behind **two separate
NLBs**, so within a subzone external-dns writes:

- **Web / grafana** → **ALIAS A** to the **ingress-nginx NLB** (from the Ingress host); cert via
  **HTTP-01** through ingress-nginx.
- **Telnet gate** (prod, `gate.telos.…`) → ALIAS A to the **gate NLB** (from the Service annotation);
  cert via **DNS-01** (Route53 via IRSA). HTTP-01 can't reach the gate NLB (no HTTP listener), so the
  gate cert uses DNS-01 (`k8s/addons/letsencrypt-dns01.yaml`). Staging's gate is plaintext → no cert.

## Known gotchas (see RUNBOOK for mitigations)

1. **Single-AZ EBS pinning** — EBS volumes are AZ-locked; the node group is pinned to one AZ so a
   single-replica pod and its volume never end up in different AZs. Durability ceiling: an AZ outage
   or a lost EBS volume is a total outage recoverable only from the nightly S3 backup (RPO up to ~24h).
   A single instance type in one AZ also has no capacity fallback — an Insufficient-Capacity event on a
   node replace can't self-heal; widen `instance_types` if that matters.
2. **NetworkPolicy is opt-in on EKS** — the VPC CNI does NOT enforce NetworkPolicy unless
   `enableNetworkPolicy=true` is set on the addon (the eks module sets it). Without it the default-deny
   posture in `networkpolicy.yaml` silently fails open. Ingress traffic is allowed from the
   `ingress-nginx` namespace (not `kube-system`, where Traefik used to live).
3. **DNS is CNAME-to-NLB-hostname**, not A-record-to-IP. Web/grafana CNAME the ingress NLB (HTTP-01
   cert); the prod telnet gate CNAMEs its own NLB and needs a **DNS-01** cert (HTTP-01 can't reach it).
4. **Teardown ordering** — delete the LoadBalancer Services (their NLBs) and empty the versioned S3
   backup bucket before `terraform destroy`, or the VPC / bucket deletion is blocked.
5. **Node memory** — `t4g.large` (8 GB) may be tight with the full LGTM stack; bump to `t4g.xlarge`.
