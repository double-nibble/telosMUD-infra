#!/usr/bin/env bash
#
# bootstrap-local.sh — populate local Terraform tfvars from your configured OCI CLI.
#
# Idempotent: safe to run repeatedly. It DISCOVERS your tenancy identifiers via the OCI CLI
# (tenancy, region, compartment, availability domain, object-storage namespace, and the newest
# Ubuntu 22.04 arm64 image) and writes them into the gitignored
# terraform/envs/{staging,production}/terraform.tfvars. It also creates the local SSH keypair
# if it is missing.
#
# No secrets are written or required here — Terraform authenticates from your ~/.oci/config.
# A collaborator just needs `oci setup config` done, then runs this. Nothing is hand-delivered.
#
# Prereqs: the `oci` CLI, configured and able to read your compartment.
#
# Usage:
#   scripts/bootstrap-local.sh
#
# Optional env overrides:
#   OCI_CLI_PROFILE     profile in ~/.oci/config                 (default: DEFAULT)
#   TELOS_COMPARTMENT   compartment display-name to deploy into  (default: telosmud;
#                       falls back to the tenancy root if not found)
#   TELOS_AD            availability domain name                 (default: first AD in region)
#   TELOS_SSH_KEY       SSH private key path                     (default: ~/.ssh/telos_id_ed25519)
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROFILE="${OCI_CLI_PROFILE:-DEFAULT}"
CONFIG="${OCI_CLI_CONFIG_FILE:-$HOME/.oci/config}"
COMPARTMENT_NAME="${TELOS_COMPARTMENT:-telosmud}"

die() { echo "error: $*" >&2; exit 1; }
info() { echo "  $*"; }
require() { [ -n "${2:-}" ] || die "could not discover $1 — check your OCI CLI setup / permissions"; }

command -v oci >/dev/null 2>&1 || die "the 'oci' CLI is not on PATH — install it and run 'oci setup config'"
[ -f "$CONFIG" ] || die "no OCI config at $CONFIG — run 'oci setup config'"

# Read a key from the active profile section of ~/.oci/config.
cfg_get() {
  awk -v prof="[$PROFILE]" -v key="$1" '
    $0 == prof { inb = 1; next }
    /^\[/      { inb = 0 }
    inb && $0 ~ "^" key "[ \t]*=" { sub("^" key "[ \t]*=[ \t]*", ""); gsub(/[ \t\r]/, ""); print; exit }
  ' "$CONFIG"
}

# oci discovery helper: run a query, strip the known py3.14 SyntaxWarning noise, trim.
ociq() { oci "$@" 2>/dev/null | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'; }

# Extract the string elements of a JSON array (one per line). --raw-output leaves the [ ] and
# quotes on array results, so a JMESPath list query needs this to become plain lines.
arr_strings() { sed -n 's/^"\(.*\)",\{0,1\}$/\1/p'; }

echo "==> Discovering OCI identifiers (profile: $PROFILE)"

TENANCY="$(cfg_get tenancy)";                             require "tenancy OCID"        "$TENANCY"
REGION="${OCI_CLI_REGION:-$(cfg_get region)}";            require "region"              "$REGION"
info "tenancy   $TENANCY"
info "region    $REGION"

NAMESPACE="$(ociq os ns get --query data --raw-output)";  require "object-storage namespace" "$NAMESPACE"
info "namespace $NAMESPACE"

AD="${TELOS_AD:-$(ociq iam availability-domain list --query 'data[0].name' --raw-output)}"
require "availability domain" "$AD"
info "AD        $AD"

# Compartment by display-name, case-INSENSITIVE (subtree search); fall back to the tenancy root.
lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
COMPARTMENT=""; MATCHED=""
while IFS='|' read -r cname cid; do
  [ -n "$cname" ] || continue
  if [ "$(lower "$cname")" = "$(lower "$COMPARTMENT_NAME")" ]; then
    COMPARTMENT="$cid"; MATCHED="$cname"; break
  fi
done < <(ociq iam compartment list --compartment-id "$TENANCY" \
  --compartment-id-in-subtree true --all \
  --query "data[?\"lifecycle-state\"=='ACTIVE'].join('|',[name,id])" --raw-output | arr_strings)

if [ -n "$COMPARTMENT" ]; then
  info "compartment $COMPARTMENT ($MATCHED)"
else
  echo "  warn: no compartment matching '$COMPARTMENT_NAME' — using the tenancy root." >&2
  echo "        available compartments (set TELOS_COMPARTMENT to one of these):" >&2
  ociq iam compartment list --compartment-id "$TENANCY" --compartment-id-in-subtree true --all \
    --query "data[?\"lifecycle-state\"=='ACTIVE'].name" --raw-output | arr_strings | sed 's/^/          - /' >&2
  COMPARTMENT="$TENANCY"
  info "compartment $COMPARTMENT (tenancy root)"
fi

# Newest Ubuntu 22.04 aarch64 image compatible with the A1 (Ampere) shape, in this region.
IMAGE="$(ociq compute image list --compartment-id "$TENANCY" \
  --operating-system "Canonical Ubuntu" --operating-system-version "22.04" \
  --shape "VM.Standard.A1.Flex" --sort-by TIMECREATED --sort-order DESC \
  --query "data[?contains(\"display-name\",'aarch64')] | [0].id" --raw-output)"
require "Ubuntu 22.04 arm64 image OCID" "$IMAGE"
info "image     $IMAGE"

# Local SSH keypair for the VMs — generate if absent.
SSH_KEY="${TELOS_SSH_KEY:-$HOME/.ssh/telos_id_ed25519}"
SSH_KEY="${SSH_KEY/#\~/$HOME}"
SSH_PUB="$SSH_KEY.pub"
if [ ! -f "$SSH_KEY" ]; then
  echo "==> Generating SSH keypair at $SSH_KEY"
  mkdir -p "$(dirname "$SSH_KEY")"
  ssh-keygen -t ed25519 -f "$SSH_KEY" -N '' -C "telos-oci" >/dev/null
else
  info "ssh key   $SSH_KEY (exists)"
fi

write_tfvars() {
  local env="$1" out="$REPO_ROOT/terraform/envs/$1/terraform.tfvars"
  cat > "$out" <<EOF
# GENERATED by scripts/bootstrap-local.sh — re-run the script instead of hand-editing.
# Identifiers only (no credentials; Terraform auth comes from ~/.oci/config). Gitignored.
region               = "$REGION"
tenancy_ocid         = "$TENANCY"
compartment_ocid     = "$COMPARTMENT"
availability_domain  = "$AD"
image_ocid           = "$IMAGE"
ssh_public_key_path  = "$SSH_PUB"
ssh_private_key_path = "$SSH_KEY"
EOF
  echo "  wrote $out"
}

echo "==> Writing tfvars"
write_tfvars staging
write_tfvars production

cat <<EOF

Done. Next:
  1. (first run) comment out the backend "s3" block in terraform/envs/staging/backend.tf to use local state
  2. cd terraform/envs/staging && terraform init && terraform apply
  3. terraform output -raw kubeconfig > ~/.kube/telos-staging
See RUNBOOK.md for the full path.
EOF
