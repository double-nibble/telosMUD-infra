# telosMUD-infra

A one-click **demo** deployment of [TelosMUD](../gomud) to **AWS EKS**. This is not a production
application manager — it's a reference for standing the whole stack up on real infrastructure,
exercising it, and tearing it down to stop paying. Deliberately single-node, single-AZ, throwaway.

**Lifecycle is two GitHub Actions:** **`up`** builds an entire environment; **`down`** destroys it.
Everything in between (secrets, DNS, TLS, the app) is automatic — no manual `kubectl`/`aws`.

- **Build:** Actions → **up** → pick env → Run &nbsp;(`gh workflow run up.yml -f env=staging`)
- **Destroy:** Actions → **down** → env, type `DESTROY` &nbsp;(`gh workflow run down.yml -f env=staging -f confirm=DESTROY`)

---

## First-time bootstrap (do once; survives `down`)

Four things can't live in the pipeline — a chicken-and-egg credential, external identity, or a domain
you own. Set them up once and then live on `up`/`down`.

### 1. AWS OIDC role — the keyless CI identity (→ `AWS_ROLE_ARN` secret)

```sh
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
aws iam create-open-id-connect-provider --url https://token.actions.githubusercontent.com \
  --client-id-list sts.amazonaws.com --thumbprint-list 1c58a3a8518e8759bf075b76b750d4f2df264fcd
cat > trust.json <<EOF
{ "Version":"2012-10-17","Statement":[{ "Effect":"Allow",
  "Principal":{"Federated":"arn:aws:iam::${ACCOUNT}:oidc-provider/token.actions.githubusercontent.com"},
  "Action":"sts:AssumeRoleWithWebIdentity",
  "Condition":{"StringEquals":{"token.actions.githubusercontent.com:aud":"sts.amazonaws.com"},
    "StringLike":{"token.actions.githubusercontent.com:sub":"repo:double-nibble/telosMUD-infra:*"}}}]}
EOF
aws iam create-role --role-name telosmud-ci --assume-role-policy-document file://trust.json
aws iam attach-role-policy --role-name telosmud-ci --policy-arn arn:aws:iam::aws:policy/AdministratorAccess
```

### 2. Terraform state bucket (globally-unique; change `bucket` in `terraform/envs/*/backend.tf` if taken)

```sh
aws s3api create-bucket --bucket telosmud-tfstate --region us-east-1
aws s3api put-bucket-versioning --bucket telosmud-tfstate --versioning-configuration Status=Enabled
aws s3api put-public-access-block --bucket telosmud-tfstate \
  --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
```

### 3. Root Route53 zone

Own the domain and have its hosted zone in Route53 (`root_dns_zone_name`, default `double-nibble.com`).
`up` creates each env's own subzone (`staging.telos.…` / `telos.…`) and NS delegation automatically.

### 4. GitHub OAuth app (one per env)

Register at `github.com/settings/developers`, callback `https://<web-host>/auth/github/callback`. Keep
the client id/secret for the secrets below.

### GitHub Actions secrets

```sh
gh secret set AWS_ROLE_ARN --body "arn:aws:iam::<acct>:role/telosmud-ci"
gh secret set POSTGRES_PASSWORD --body "$(openssl rand -hex 24)"        # URL-safe; a fresh DB each up
gh secret set TELOS_WEB_SESSION_KEY --body "$(openssl rand -base64 32)"
gh secret set TELOS_GITHUB_CLIENT_ID          # from step 4
gh secret set TELOS_GITHUB_CLIENT_SECRET
gh secret set GRAFANA_ADMIN_PASSWORD --body "$(openssl rand -base64 24)"   # optional (Grafana)
```

Production additionally needs `TELOS_ACCOUNT_{CALLER_TOKEN,SIGNING_KEY,VERIFY_KEY}` and
`TELOS_HANDOFF_{SIGNING,VERIFY}_KEY`. That's the entire manual surface.

---

## What `up` creates (per environment, ~20 min)

**Infrastructure** (Terraform) — a VPC (2 AZs, single NAT) · an **EKS** cluster + one single-AZ
Graviton (arm64) node group · cluster addons: **EBS CSI** (default `gp3`), **ingress-nginx**,
**cert-manager**, **external-dns** · a per-env **Route53 subzone** delegated from the root · an **S3
backup bucket** · **IRSA** roles scoping external-dns + cert-manager to that env's subzone only.

**Application** (Kustomize) — `world` · `gate` · `account` · `postgres` + `nats` on gp3 EBS · `redis` ·
`db-init` (migrate + content import) · a nightly `pg-backup` CronJob → S3 · the **LGTM** observability
stack (Loki, Prometheus, Grafana, OTel Collector). The deploy step creates the cluster Secrets from the
GH secrets above and applies the Let's Encrypt issuers.

**Front doors** — two AWS NLBs: the raw-TCP **telnet gate** (`gate.<host>:4000`) and the
**web/OAuth + Grafana** ingress (`<host>:443`). external-dns writes the DNS records; cert-manager issues
the certs. All automatic.

```
terraform/   modules/{network,eks,cluster-bootstrap} · envs/{staging,production}
k8s/         base/ · overlays/{staging,production} · addons/ (Let's Encrypt issuers)
.github/     up.yml · down.yml · deploy.yml · terraform.yml · validate.yml
```

It's a demo, so the source is the documentation — the workflow files and Terraform/Kustomize comments
explain the details.
