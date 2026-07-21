# Deploying a TelosMUD

A cloud-agnostic guide to standing up your own MUD on the **Telos** system. It assumes you're
an operator/admin who wants to *run* a MUD — not someone who works on the engine. You do not
need to build or understand the Go codebase.

You'll deploy the Telos server components onto a Kubernetes cluster, load a **content pack**
(the actual world — rooms, mobs, items, abilities), and let players connect over telnet and a
web sign-in.

- **The engine:** [`double-nibble/telosMUD`](https://github.com/double-nibble/telosMUD) — publishes
  container images you deploy. You don't clone it to run it.
- **The content:** [`double-nibble/telosMUD-content`](https://github.com/double-nibble/telosMUD-content)
  — an *example* content pack. You can run it as-is, fork it, or author your own.

> There is a concrete reference implementation of everything below (AWS EKS + Terraform) in this
> repository's [`terraform/`](terraform/) and [`k8s/`](k8s/) directories, and in
> [RUNBOOK.md](RUNBOOK.md). This guide is the vendor-neutral version.

---

## 1. What you're deploying

Telos is several small services plus three infrastructure dependencies. For a normal MUD
(hundreds of players or fewer) you run **one of each** — this is the "single-shard" topology,
where one world process hosts every zone.

| Component | What it is | Listens on | Needs |
|---|---|---|---|
| **telos-gate** | The front door. Raw-TCP **telnet** (and optional TLS). Handles login. | `4000` (telnet) | Redis, NATS, world, account |
| **telos-world** | The game engine. Hosts the zones and runs the simulation. | `9090` (gRPC, internal) | Postgres, Redis, NATS |
| **telos-account** | Accounts/auth API **and** the sign-in **website**. | `9100` (gRPC, internal), `8080` (web) | Postgres, Redis |
| **telos-migrate** | One-shot: creates/upgrades the database schema. | — | Postgres |
| **telos-seed** *or* **telos-pull** | One-shot: loads a content pack into the database. | — | Postgres (+ content source) |
| **Postgres** | Source of truth: content definitions + player state. | `5432` | a persistent volume |
| **Redis** | Login directory, link codes, sessions, comms fan-in. | `6379` | — (ephemeral) |
| **NATS (JetStream)** | Cross-zone events and player comms. | `4222` | a small volume |

Data flow: **migrate** builds the schema → **seed/pull** writes your content into Postgres →
**world** loads that content and runs the game → **gate** is what players connect to and it
brokers login through **account**.

```
  player ──telnet:4000──▶  gate  ──gRPC──▶  world  ◀──▶  Postgres / Redis / NATS
  browser ─https──────▶  account (website + auth)  ◀── gate (login handshake)
```

---

## 2. Prerequisites

### 2.1 A Kubernetes cluster
Any conformant cluster works — managed (GKE, EKS, AKS, DigitalOcean, Linode) or self-hosted
(k3s, kubeadm, k0s). It must provide:

- **A way to expose a raw-TCP port** for telnet. This is the one non-negotiable constraint:
  the gate is **not** HTTP, so HTTP-only ingress (and HTTP-only serverless platforms) cannot
  front it. In Kubernetes terms you need a `Service` of type **`LoadBalancer`** (every managed
  cloud provides one; k3s ships the built-in "servicelb" that binds the port on the node) or a
  **`NodePort`** you put your own TCP load balancer in front of.
- **An ingress controller** for the sign-in website over HTTPS (e.g. Traefik — bundled with
  k3s — or ingress-nginx).
- **[cert-manager](https://cert-manager.io/)** for automatic TLS certificates (Let's Encrypt).
- **A default `StorageClass`** (ReadWriteOnce) for Postgres/NATS volumes.

### 2.2 A domain name
You need a hostname you control (e.g. `mud.example.com`). It's required for:
- HTTPS on the sign-in website, and
- the GitHub OAuth callback (which must be a stable, real URL).

You'll point DNS at your gate/ingress address. With a fixed IP that's an **A-record**; with a cloud
load balancer that hands out a hostname (as EKS does) it's a **CNAME** to the LB hostname (see
[RUNBOOK.md](RUNBOOK.md) for how the AWS reference implementation wires this).

### 2.3 A login provider (GitHub OAuth)
Players sign in through your website with GitHub OAuth, then get a one-time link code they
paste into the telnet session. You'll register a **GitHub OAuth App** (§6).

### 2.4 Container images
Use the prebuilt, multi-arch (amd64 + arm64) images published by the engine repo:

```
ghcr.io/double-nibble/telos-gate
ghcr.io/double-nibble/telos-world
ghcr.io/double-nibble/telos-account
ghcr.io/double-nibble/telos-migrate
ghcr.io/double-nibble/telos-seed
```

Pin a real tag (a release tag or a commit SHA) rather than `latest` for anything you care
about. If the packages are private, create an image-pull secret; if public, no secret is
needed. To build your own instead, see the engine repo's `deploy/Dockerfile`.

### 2.5 A content pack
The world is data. You need one of:
- **The bundled demo** — no external content needed; the `telos-seed` image carries it. Great
  for a first bring-up.
- **Your own pack** — author it (or fork `telosMUD-content`) and publish it as a versioned,
  git-hosted content store that `telos-pull` imports. See §5.

### 2.6 Local tooling
`kubectl` (and `kustomize`, bundled with recent `kubectl`) configured against your cluster, and
a way to manage secrets (plain `kubectl`, or SOPS/sealed-secrets for GitOps).

---

## 3. Get the manifests

The reference Kubernetes manifests live in [`k8s/`](k8s/) of this repo as a Kustomize layout:

```
k8s/base/                # the Deployments/StatefulSets/Services/Jobs for every component
k8s/overlays/<env>/      # per-environment settings (image tags, config, secrets, ingress)
```

Copy `k8s/` into your own repo and adapt an overlay for your MUD. The base is vendor-neutral;
only the overlay changes per deployment. If you're not using Kustomize, the base files are
plain Kubernetes YAML you can apply directly and edit by hand.

Everything below refers to that layout, but the *concepts* apply to any manifest set.

---

## 4. Configuration reference

Telos is configured entirely by `TELOS_*` environment variables (or a mounted config file).
Set non-secret values in a `ConfigMap` and secrets in a `Secret`. The important ones:

### Shared (all services)
| Variable | Meaning |
|---|---|
| `TELOS_POSTGRES_DSN` | `postgres://user:pass@postgres:5432/telosmud?sslmode=…` (secret) |
| `TELOS_REDIS_ADDR` | `redis:6379` |
| `TELOS_NATS_URL` | `nats://nats:4222` |
| `TELOS_ENV` | `dev` / `prod` (labeling; does not relax security by itself) |
| `TELOS_LOG_LEVEL` | `info` / `debug` |

### telos-world
| Variable | Meaning |
|---|---|
| `TELOS_WORLD_LISTEN` | `:9090` |
| `TELOS_SHARD_ID` | Unique id for this world process (e.g. `shard-a`) |
| `TELOS_SHARD_ADDR` | How peers/gate reach it (e.g. `world:9090`) |
| `TELOS_ZONES` | Zones this world **hosts** — for single-shard, list them all |
| `TELOS_HANDOFF_SIGNING_KEY` / `_VERIFY_KEY` | Cross-shard handoff keypair (multi-shard only) |
| `TELOS_ALLOW_INSECURE` | Dev opt-in that permits keyless handoffs; leave **unset** in production |

### telos-account
| Variable | Meaning |
|---|---|
| `TELOS_ACCOUNT_LISTEN` | `:9100` (internal gRPC) |
| `TELOS_WEB_LISTEN` | `:8080` (the website) |
| `TELOS_WEB_PUBLIC_URL` | Public base URL, e.g. `https://mud.example.com` — the login link + OAuth callback derive from this |
| `TELOS_WEB_SECURE_COOKIES` | `1` in production (HTTPS); `0` only for plain-http dev |
| `TELOS_WEB_SESSION_KEY` | Random 32+ byte cookie-signing key (secret) |
| `TELOS_GITHUB_CLIENT_ID` / `_CLIENT_SECRET` | Your GitHub OAuth app credentials (secret) |
| `TELOS_ACCOUNT_CALLER_TOKEN` | Shared token the gate presents to the account gRPC API (secret) |
| `TELOS_ACCOUNT_SIGNING_KEY` / `_VERIFY_KEY` | Keypair for signed session assertions (secret) |
| `TELOS_BOOTSTRAP_ADMIN` | Grants the first matching account staff/admin on first run |

### telos-gate
| Variable | Meaning |
|---|---|
| `TELOS_GATE_LISTEN` | `:4000` (plaintext telnet listener) |
| `TELOS_GATE_ALLOW_PLAINTEXT` | `1` to allow plain telnet; leave unset for TLS-only |
| `TELOS_GATE_TLS_LISTEN` / `_TLS_CERT` / `_TLS_KEY` | TLS telnet listener + mounted cert/key |
| `TELOS_ACCOUNT_TARGET` | `account:9100` — enables account-backed OAuth login |
| `TELOS_ACCOUNT_CALLER_TOKEN` | Must match the account's token (secret) |
| `TELOS_WORLD_TARGET` | `world:9090` — fallback if the directory is unreachable |
| `TELOS_ZONES` | The **spawn** zone new players start in |

### Content (for `telos-pull`)
| Variable | Meaning |
|---|---|
| `TELOS_CONTENT_URL` | Git URL of your content store |
| `TELOS_CONTENT_VERSION` | The tag/SHA to import |
| `TELOS_CONTENT_TOKEN` | Access token if the content repo is private (secret) |
| `TELOS_CONTENT_PACKS` | Which pack(s) to import |

> Note: `TELOS_DEV_AUTOAUTH` (a bare-name login bypass) exists for local development but is
> **compiled out of the released images** — production images enforce OAuth and cannot be made
> to skip it. Plan on real OAuth for any real deployment.

---

## 5. Prepare your content

### Option A — run the bundled demo (fastest)
Do nothing special. The database-init step (§7) uses **`telos-seed`**, which carries the demo
pack inside the image and writes it to Postgres as `pack='demo'`. Good for proving the stack
works end-to-end.

### Option B — run your own content
Content packs are directory trees (rooms, mobs, items, abilities, tables…). Start from
[`telosMUD-content`](https://github.com/double-nibble/telosMUD-content) — read its README for the
authoring format — then publish it as a **versioned content store**:

1. Author/fork the pack in your own git repo.
2. Stamp a manifest for a release (the engine ships the tool for this):
   ```
   telos-pull --emit-manifest --manifest-version v1 --dir .
   ```
   This writes a `manifest.yaml` (content hash + pack list) into the tree.
3. Commit and **tag** that version (e.g. `v1`).

At deploy time you swap the seed step for **`telos-pull`**, pointed at your repo:
```
TELOS_CONTENT_URL=https://github.com/you/your-content
TELOS_CONTENT_VERSION=v1
```
`telos-pull` resolves the tag, verifies the tree against the manifest, and imports the packs
into Postgres atomically. The world only ever reads content from Postgres — it never pulls — so
loading content and running the game are cleanly separated. To update content later, publish a
new version and re-run `telos-pull` with the new `TELOS_CONTENT_VERSION`.

---

## 6. Register the GitHub OAuth app

At <https://github.com/settings/developers> → **New OAuth App**:
- **Homepage URL:** `https://mud.example.com`
- **Authorization callback URL:** `https://mud.example.com/auth/github/callback`

Copy the **Client ID** and generate a **Client secret**. These become
`TELOS_GITHUB_CLIENT_ID` / `TELOS_GITHUB_CLIENT_SECRET` (§8). The callback host **must** match
`TELOS_WEB_PUBLIC_URL` exactly.

---

## 7. Deploy, step by step

The commands below assume the Kustomize layout from §3 and namespace `telosmud`.

### 7.1 Cluster add-ons (once)
Install cert-manager and create a Let's Encrypt issuer:
```sh
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/latest/download/cert-manager.yaml
kubectl apply -f k8s/addons/letsencrypt-issuer.yaml   # edit the email first
```

### 7.2 Secrets
Create the `telos-secrets` Secret with (at minimum): `POSTGRES_PASSWORD`, `TELOS_POSTGRES_DSN`,
`TELOS_WEB_SESSION_KEY`, `TELOS_ACCOUNT_CALLER_TOKEN`, the account signing/verify keypair, and
your `TELOS_GITHUB_CLIENT_ID` / `TELOS_GITHUB_CLIENT_SECRET`. Generate strong values, e.g.:
```sh
openssl rand -base64 32     # for tokens / session key
```
Never commit plaintext secrets. For GitOps, encrypt with SOPS/age or use sealed-secrets.

### 7.3 Deploy everything
```sh
kubectl apply -k k8s/overlays/<your-env>
kubectl -n telosmud get pods -w
```
Ordering is handled for you: Postgres/Redis/NATS come up, then a **db-init** Job runs
`telos-migrate` (schema) followed by `telos-seed` **or** `telos-pull` (content), and the
world/gate/account wait for it to complete before booting.

### 7.4 DNS + TLS
Point your domain's **A-record** at the address of the gate `LoadBalancer` Service (and the
ingress, which is typically the same node/LB):
```sh
kubectl -n telosmud get svc gate            # note the external address
```
Once DNS resolves, cert-manager completes the HTTP-01 challenge and issues the website's
certificate automatically. Confirm:
```sh
kubectl -n telosmud get certificate
```

---

## 8. Verify

```sh
# Cluster + workloads healthy
kubectl -n telosmud get pods

# Website serves over real HTTPS
curl -I https://mud.example.com/

# Telnet front door is live
telnet mud.example.com 4000
```

Then do a real login: telnet in, open the printed `https://…/login/<code>` link in a browser,
sign in with GitHub, and you'll drop into the game. Grant yourself staff by setting
`TELOS_BOOTSTRAP_ADMIN` to your account identifier before first login.

---

## 9. Production hardening checklist

- [ ] **TLS-only telnet:** set `TELOS_GATE_TLS_LISTEN` + cert/key (mounted from a cert-manager
      Secret); drop `TELOS_GATE_ALLOW_PLAINTEXT`.
- [ ] **`TELOS_WEB_SECURE_COOKIES=1`** and an `https://` `TELOS_WEB_PUBLIC_URL`.
- [ ] **`TELOS_ACCOUNT_CALLER_TOKEN`** set (and matched on the gate) so the account gRPC API
      isn't open.
- [ ] **Account signing/verify keypair** set (`TELOS_ACCOUNT_SIGNING_KEY` / `_VERIFY_KEY`).
- [ ] **No dev flags:** `TELOS_ALLOW_INSECURE` and `TELOS_DEV_AUTOAUTH` unset.
- [ ] **Strong secrets** (DB password, session key, tokens) — not the examples.
- [ ] **Backups:** schedule `pg_dump` of Postgres to off-cluster storage (a `CronJob`).
- [ ] **Stable address:** a reserved/static IP so DNS + OAuth callback never break on a node
      replacement.

---

## 10. Operations

- **Upgrade the engine:** bump the image tag in your overlay and re-apply. The `db-init` Job
  re-runs `telos-migrate`, which is idempotent and advisory-locked.
- **Update content:** publish a new content version (§5) and re-run the `telos-pull` step with
  the new `TELOS_CONTENT_VERSION`. Running worlds hot-reload changed content; shared definition
  changes may need a rolling restart.
- **Backups / restore:** `pg_dump` on a schedule; restore by piping a dump into the Postgres
  pod's `psql`. Redis is ephemeral (rebuildable); NATS JetStream holds durable events on its
  volume.
- **Scaling beyond one node:** the single-shard topology is fine for typical MUD populations.
  To scale, move Postgres/Redis/NATS out of the cluster (or to HA), run multiple `telos-world`
  shards each hosting a subset of zones (distinct `TELOS_SHARD_ID`), and configure the
  cross-shard handoff keypair (`TELOS_HANDOFF_*`). The application doesn't change — placement is
  configuration.

---

## 11. Troubleshooting

| Symptom | Cause / fix |
|---|---|
| Telnet connection hangs or refuses | The gate isn't exposed over raw TCP. You need a `LoadBalancer`/`NodePort`, not HTTP ingress. Check `kubectl -n telosmud get svc gate` has an external address, and that your firewall allows `4000`. |
| Pods stuck `ImagePullBackOff` | Private images without a pull secret, or wrong arch. Make the packages public or add an image-pull secret; ensure the image supports your nodes' architecture (arm64/amd64). |
| Login page says "sign-in is not configured" | `TELOS_GITHUB_CLIENT_ID`/`_SECRET` empty. Set them and restart `telos-account`. |
| OAuth returns a redirect/callback error | The GitHub app's callback URL doesn't exactly match `TELOS_WEB_PUBLIC_URL` + `/auth/github/callback`, or `TELOS_WEB_PUBLIC_URL` isn't the public HTTPS host. |
| Website certificate never issues | DNS A-record not pointing at the ingress yet, or port 80 blocked (HTTP-01 needs it). Check `kubectl -n telosmud describe certificate`. |
| World won't start / can't find content | The db-init step didn't complete, or `telos-pull` couldn't reach your content store. Check the `db-init` Job logs. |
| `kubectl` to your cluster hangs | Unrelated to Telos — your cluster's API endpoint isn't reachable (firewall/port). |

---

For a fully worked concrete example (AWS EKS, Terraform, NLB for telnet, ingress-nginx + cert-manager
Let's Encrypt), see [PLAN.md](PLAN.md) and [RUNBOOK.md](RUNBOOK.md) in this repository.
