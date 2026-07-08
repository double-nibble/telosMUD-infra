# TelosMUD deployment plan

A $0, two-environment (staging + production) Kubernetes deployment for a low-traffic
(2–3 concurrent users) proof-of-concept.

## Decisions (settled)

| Decision | Choice | Why |
|---|---|---|
| Provider | **Oracle Cloud Always-Free** | Only genuine $0 K8s-capable compute (4 ARM cores / 24 GB / 200 GB block, no expiry). |
| Kubernetes | **k3s** (one node per env) | Conformant K8s in a single binary; built-in `servicelb` gives a free L4 LoadBalancer. |
| Isolation | **Two clusters, two VMs** | Clean blast-radius separation; both fit in the free A1 pool. |
| IaC | **Terraform (OCI provider)** | All infra as HCL, per the brief. State in an OCI Object Storage bucket. |
| App delivery | **GitHub Actions + Kustomize** | `kustomize build overlays/<env> \| kubectl apply`. No extra in-cluster services. |
| World topology | **Single-shard** (all zones, one world) | No cross-shard handoff → no director, no handoff keypair. Mirrors `docker-compose.single.yml`. |
| Images | **arm64, GHCR** | A1 is ARM; app binaries are static `CGO_ENABLED=0`, so cross-compile is free. |

## Why not the "obvious" options

- **GKE / EKS managed control planes** can't reach $0: EKS is ~$73/mo/cluster; GKE waives
  the fee for one cluster but nodes cost money, and a `LoadBalancer` Service for the raw-TCP
  telnet gate is ~$18/mo per env.
- **Cloud Run / App Engine / Lambda** are HTTP/gRPC-only ingress — they cannot terminate the
  gate's **raw TCP telnet** connection. Non-starter for the front door.
- **Managed Postgres/Redis** (~$15/mo each) is the other budget-killer; self-host in-cluster.
- **GCP always-free** is one `e2-micro` (1 GB) — too small for k3s + the whole stack.

The single cost-defining constraint is that **`telos-gate` is a raw TCP telnet listener.**
k3s's Klipper `servicelb` binds the telnet port on the node's public IP via `hostPort`, so
we get an L4 LoadBalancer for free. That trick is what makes K8s affordable here.

## Resource budget (Oracle Always-Free A1)

Allotment: **4 OCPU + 24 GB RAM + 200 GB block storage**, poolable across ≤4 VMs.

| | Staging VM | Production VM |
|---|---|---|
| Shape | `VM.Standard.A1.Flex` 2 OCPU / 12 GB | `VM.Standard.A1.Flex` 2 OCPU / 12 GB |
| Boot volume | ~50 GB | ~50 GB |
| OS image | Ubuntu 22.04 **arm64** | Ubuntu 22.04 **arm64** |

Idle footprint per env (k3s ~512 MB + PG + Redis + NATS + world + gate + account) is well
under 2 GB, so 12 GB is generous headroom.

## Per-cluster architecture

```
                 Internet
                    │
        ┌───────────┴───────────┐
        │  Oracle A1 VM (k3s)    │
        │                        │
  telnet:4000/tls ── Service(LoadBalancer, servicelb) ─▶ telos-gate
   web:443 ──────── Traefik Ingress + cert-manager ────▶ telos-account (web :8080)
        │                        │
        │   telos-world (:9090, single shard, all zones)
        │   telos-account (:9100 gRPC)
        │   postgres / redis / nats  (StatefulSets, local-path PVCs)
        │   migrate + seed  (Jobs, run-once on deploy)
        └────────────────────────┘
```

- **Telnet** → `Service type: LoadBalancer` (Klipper binds it on the node IP). Free.
- **Web/OAuth** → Traefik (bundled with k3s) + **cert-manager** (Let's Encrypt). The same LE
  cert is mounted into the gate for **telnet TLS** (`TELOS_GATE_TLS_CERT/KEY`).
- **Data** → StatefulSets on `local-path` PVCs. Backup = `pg_dump` CronJob → OCI Object Storage.

## Prod hardening deltas (base → production overlay)

The dev compose documents exactly what flips in prod. The production overlay must:

| Setting | dev/staging | production |
|---|---|---|
| `TELOS_ALLOW_INSECURE` | `1` | unset (provide `TELOS_HANDOFF_*` keypair if the single-node boot guard needs it — **verify**) |
| `TELOS_DEV_AUTOAUTH` | `1` (staging) | unset |
| `TELOS_GATE_ALLOW_PLAINTEXT` | `1` | unset (TLS-only via `TELOS_GATE_TLS_LISTEN/CERT/KEY`) |
| `TELOS_ACCOUNT_CALLER_TOKEN` | unset | set (gRPC caller auth, #247) |
| `TELOS_ACCOUNT_SIGNING_KEY` / `_VERIFY_KEY` | unset | set (signed session assertions) |
| `TELOS_WEB_SECURE_COOKIES` | `0` | `1` |
| `TELOS_WEB_PUBLIC_URL` | `http://localhost:8080` | `https://<domain>` |
| `TELOS_WEB_SESSION_KEY` | dev default | strong random secret |
| `TELOS_GITHUB_CLIENT_ID/SECRET` | dev OAuth app | prod OAuth app (real callback URL) |
| Postgres password | `telos` | strong random secret |

> **Staging** can keep `TELOS_DEV_AUTOAUTH=1` (bare-name login) so you can smoke-test the
> telnet path without OAuth. **Production** requires a domain + real GitHub OAuth app.

## Secrets

**SOPS + age.** Encrypted secret manifests are committed to this repo; CI decrypts them with
an age key stored as a GitHub Actions secret. Keeps the repo self-contained and avoids a
sprawl of raw Actions secrets. `.sops.yaml` pins which files are encrypted.

Secrets to manage per env: Postgres password, `TELOS_ACCOUNT_CALLER_TOKEN`, account
signing/verify keypair, `TELOS_WEB_SESSION_KEY`, GitHub OAuth client id/secret, the GHCR
image-pull token, and (prod) the cert-manager DNS provider token.

## CI/CD

- **`gomud` (app repo)** — on merge/tag: `docker buildx` → push **arm64** images to
  `ghcr.io/<owner>/telos-{gate,world,account,migrate,seed}`. *(This is a change to the app
  repo's existing workflow — its Dockerfile already builds static binaries; add `linux/arm64`.)*
- **`telosMUD-infra` (this repo)**:
  - `terraform.yml` — `plan` on PR, `apply` on merge, matrixed over `envs/{staging,production}`.
  - `deploy.yml` — `sops -d` secrets → `kustomize build overlays/<env>` → `kubectl apply`,
    using a per-env kubeconfig stored as a GitHub Actions secret.

## Terraform state

An **OCI Object Storage bucket** (S3-compatible backend), also free-tier. One bucket, a key
per environment. Configured in `terraform/envs/*/backend.tf`.

## Domain & TLS

A ~$10/yr domain is the only unavoidable non-free cost, needed for real GitHub OAuth (secure
cookies require a stable HTTPS host). cert-manager issues Let's Encrypt certs via **DNS-01**
(free Cloudflare zone) so no inbound port 80 is required. `staging.<domain>` and `<domain>`
point at the two node IPs.

## Known gotchas (see RUNBOOK for mitigations)

1. **A1 free capacity is scarce** — "out of host capacity" is common in busy regions; pick a
   quiet region/AD and let Terraform retry.
2. **Host firewall** — Oracle instances block all but SSH at the instance level *and* the VCN
   security list. cloud-init opens the telnet/web ports in `iptables`; the network module opens
   the security list. Ubuntu images avoid the `firewalld` variant.
3. **arm64 images** — the app CI must publish arm64 or the pods won't schedule on A1.
4. **Single-node handoff guard** — confirm whether a single-shard world still trips the keyless
   handoff boot guard; if so, provide `TELOS_HANDOFF_SIGNING_KEY/VERIFY_KEY` rather than leaving
   `TELOS_ALLOW_INSECURE` on in production.

## Open items before first apply

- [ ] OCI tenancy/compartment OCIDs, region, and an uploaded SSH public key (`*.tfvars`).
- [ ] Register a domain; create two GitHub OAuth apps (staging + prod callback URLs).
- [ ] Add `linux/arm64` to the `gomud` image build workflow.
- [ ] Generate the age key; add it to both repos' Actions secrets.
- [ ] Verify the gate's TLS cert env wiring and the single-node handoff-guard question above.
