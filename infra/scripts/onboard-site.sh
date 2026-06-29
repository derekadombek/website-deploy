#!/usr/bin/env bash
#
# Onboard a site, babysitting Route 53 delegation so the apply never hangs at
# ACM validation waiting for an external registrar.
#
# Phases (--phase):
#   all          (default, local use) — create the zone, print the nameservers,
#                poll public DNS until delegation is live, then full apply.
#   create-zone  (CI phase 1) — create JUST the hosted zone and print its
#                nameservers, then stop. No waiting. You then set those NS at the
#                external registrar.
#   finish       (CI phase 2, after you've delegated + resumed) — poll until the
#                delegation is live, then full apply.
#
# For an existing-zone env, or one with registrar_in_route53 = true, there's
# nothing to delegate — it just applies.
#
# Auth: uses the active AWS creds/profile (local) or OIDC role (CI).
#
# Guardrail: refuses to apply against empty Terraform state unless CONFIRM_FRESH
# is set — empty state on a re-run means lost/mis-pointed state, and applying
# would recreate resources + silently duplicate the Route 53 zone. Set
# CONFIRM_FRESH=1 only for the first-ever provision of an env.
#
# Usage:
#   AWS_PROFILE=<bootstrap> onboard-site.sh [--phase all|create-zone|finish] <env>
#   CONFIRM_FRESH=1 onboard-site.sh --phase create-zone <env>   # first run

set -euo pipefail

PHASE="all" ENV_NAME=""
while [ $# -gt 0 ]; do
  case "$1" in
    --phase) PHASE="$2"; shift 2;;
    -*) echo "unknown option: $1" >&2; exit 1;;
    *) ENV_NAME="$1"; shift;;
  esac
done
[ -n "${ENV_NAME}" ] || { echo "usage: onboard-site.sh [--phase all|create-zone|finish] <env>" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_DIR="${SCRIPT_DIR}/../envs/${ENV_NAME}"
POLL_INTERVAL=30  # seconds between delegation checks
POLL_TIMEOUT=3600 # give up after 1h of waiting on the registrar

[ -d "${ENV_DIR}" ] || { echo "no such env: ${ENV_DIR}" >&2; exit 1; }
cd "${ENV_DIR}"

confirm_fresh_or_refuse() {
  # An empty state means Terraform will CREATE everything — correct on a genuine
  # first run, but on a RE-RUN it usually means lost/mis-pointed state, and
  # applying would collide with existing resources AND duplicate the Route 53
  # zone (Route 53 allows same-name zones). Require explicit acknowledgement.
  [ -n "$(terraform state list 2>/dev/null)" ] && return 0
  case "${CONFIRM_FRESH:-}" in
    1 | true | yes) echo "==> empty state + CONFIRM_FRESH set — first-time provision" ;;
    *)
      cat >&2 <<EOF
REFUSING TO APPLY: Terraform state for '${ENV_NAME}' is empty.
  - FIRST time provisioning this env?  Re-run with CONFIRM_FRESH=1
    (or set confirm_fresh: true on the workflow).
  - Provisioned it before?  Your state is missing or the backend in versions.tf
    is mis-pointed. Fix the backend first — applying now would recreate
    resources and create a duplicate Route 53 zone.
EOF
      exit 2
      ;;
  esac
}

create_zone() {
  echo "==> creating hosted zone (if this env creates one)"
  # No-op when create_hosted_zone = false (the resource has zero instances).
  terraform apply -input=false -auto-approve \
    -target='module.site.aws_route53_zone.primary' \
    -target='module.site.aws_route53domains_registered_domain.this' >/dev/null 2>&1 || true
}

zone_ns_json() { terraform output -json hosted_zone_name_servers 2>/dev/null || echo '[]'; }
has_zone() { [ "$(zone_ns_json | tr -d '[:space:]')" != "[]" ]; }

print_ns() {
  local domain; domain="$(terraform output -raw hosted_zone_name)"
  echo
  echo "==> Hosted zone created for ${domain}. Set these nameservers at the registrar:"
  zone_ns_json | tr -d '[:space:]' | tr ',' '\n' | sed 's/[]["]//g' | grep . | sed 's/^/      /'
  echo
}

wait_for_delegation() {
  local domain; domain="$(terraform output -raw hosted_zone_name)"
  echo "==> waiting for delegation of ${domain} to go live…"
  local deadline=$(( $(date +%s) + POLL_TIMEOUT ))
  until live="$(dig +short NS "${domain}" @1.1.1.1 2>/dev/null)"; [ -n "${live}" ] && echo "${live}" | grep -qi 'awsdns'; do
    if [ "$(date +%s)" -ge "${deadline}" ]; then
      echo "timed out waiting for delegation. Once it's live, re-run --phase finish." >&2
      exit 1
    fi
    sleep "${POLL_INTERVAL}"
  done
  echo "==> delegation is live."
}

full_apply() {
  echo "==> full apply"
  terraform apply -input=false -auto-approve
  echo "==> done. Set the repo Variables from: terraform output"
}

echo "==> terraform init"
terraform init -input=false >/dev/null

case "${PHASE}" in
  create-zone)
    confirm_fresh_or_refuse
    create_zone
    if has_zone; then
      print_ns
      echo "==> Next: set those NS at the external registrar, then resume (phase finish)."
    else
      echo "==> no zone to delegate (existing zone, or registrar_in_route53/auto)."
      echo "    Nothing to delegate — just run the normal Terraform workflow to apply."
    fi
    ;;
  finish)
    has_zone && wait_for_delegation
    full_apply
    ;;
  all)
    confirm_fresh_or_refuse
    create_zone
    if has_zone; then print_ns; wait_for_delegation; fi
    full_apply
    ;;
  *)
    echo "unknown phase: ${PHASE} (use all|create-zone|finish)" >&2; exit 1
    ;;
esac
