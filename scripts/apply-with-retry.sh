#!/usr/bin/env bash
#
# apply-with-retry.sh — beat Oracle "Out of host capacity" by retrying terraform apply across
# every availability domain until an A1 host frees up. Always-Free A1 capacity appears in short
# windows; a persistent loop catches one.
#
# It ONLY retries on capacity errors. Any other terraform failure (bad config, auth, quota)
# aborts immediately so you are not stuck looping on a real problem.
#
# Usage:
#   scripts/apply-with-retry.sh [staging|production]
#
# Env knobs:
#   RETRY_SLEEP   seconds to wait between full AD sweeps            (default: 60)
#   MAX_ROUNDS    stop after this many sweeps (0 = forever)         (default: 0)
#   OCPUS         override A1 OCPUs for this run (1 finds capacity   (default: tfvars = 2)
#                 more often than 2)
#   MEMORY_GBS    override A1 memory GB                             (default: tfvars = 12)
#
# Tip: if this keeps sweeping with no luck, upgrade the tenancy to Pay-As-You-Go — Always-Free
# A1 usage is still unbilled, but PAYG accounts are not deprioritized for A1 capacity.
#
set -uo pipefail

ENVIRONMENT="${1:-staging}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIR="$REPO_ROOT/terraform/envs/$ENVIRONMENT"
[ -d "$DIR" ] || { echo "no such env: $ENVIRONMENT" >&2; exit 2; }

RETRY_SLEEP="${RETRY_SLEEP:-60}"
MAX_ROUNDS="${MAX_ROUNDS:-0}"

# Extra -var flags for shape overrides, only if the caller set them.
VARS=()
[ -n "${OCPUS:-}" ]      && VARS+=(-var "ocpus=$OCPUS")
[ -n "${MEMORY_GBS:-}" ] && VARS+=(-var "memory_gbs=$MEMORY_GBS")

# Discover the region's availability domains (JSON array -> plain lines).
mapfile_ads() {
  oci iam availability-domain list --query 'data[].name' --raw-output 2>/dev/null \
    | sed -n 's/^[[:space:]]*"\(.*\)",\{0,1\}$/\1/p'
}
ADS=()
while IFS= read -r ad; do [ -n "$ad" ] && ADS+=("$ad"); done < <(mapfile_ads)
[ "${#ADS[@]}" -gt 0 ] || { echo "could not list availability domains (is the oci CLI configured?)" >&2; exit 2; }

echo "==> apply-with-retry: env=$ENVIRONMENT  ADs=${ADS[*]}  sleep=${RETRY_SLEEP}s  shape=${OCPUS:-tfvars}/${MEMORY_GBS:-tfvars}"

terraform -chdir="$DIR" init -input=false >/dev/null

round=0
while true; do
  round=$((round + 1))
  for AD in "${ADS[@]}"; do
    echo "==> [round $round] trying availability_domain=$AD"
    out="$(terraform -chdir="$DIR" apply -auto-approve -input=false \
             -var "availability_domain=$AD" "${VARS[@]}" 2>&1)"
    code=$?
    echo "$out" | tail -n 6

    if [ $code -eq 0 ]; then
      echo "==> SUCCESS on $AD"
      echo "    terraform -chdir=$DIR output -raw kubeconfig > ~/.kube/telos-$ENVIRONMENT"
      exit 0
    fi

    if echo "$out" | grep -qiE "Out of host capacity|LimitExceeded|InternalError.*capacity|500.*capacity"; then
      echo "==> capacity unavailable on $AD, moving on"
      continue
    fi

    echo "==> non-capacity error — aborting (fix this before retrying):" >&2
    echo "$out" | grep -iE "error" | tail -n 10 >&2
    exit $code
  done

  if [ "$MAX_ROUNDS" -ne 0 ] && [ "$round" -ge "$MAX_ROUNDS" ]; then
    echo "==> gave up after $round rounds" >&2
    exit 1
  fi
  echo "==> all ADs out of capacity; sleeping ${RETRY_SLEEP}s (round $round)"
  sleep "$RETRY_SLEEP"
done
