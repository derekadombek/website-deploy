#!/usr/bin/env bash
#
# Onboard a site end-to-end, babysitting Route 53 delegation so a single run
# never hangs at ACM validation.
#
# Flow:
#   1. terraform init + create just the hosted zone (if this env creates one).
#   2. If a zone was created AND it isn't auto-delegated, print the nameservers,
#      then poll public DNS until the registrar delegation goes live.
#   3. Run the full apply (cert validation now succeeds quickly).
#
# For an existing-zone env, or one with registrar_in_route53 = true, there's
# nothing to wait on — it just applies.
#
# Auth: uses your active AWS creds/profile (the client's bootstrap access).
#
# Guardrail: refuses to apply against empty Terraform state unless CONFIRM_FRESH
# is set — empty state on a re-run means lost/mis-pointed state, and applying
# would recreate resources + duplicate the Route 53 zone. Set CONFIRM_FRESH=1
# only for the first-ever provision of an env.
#
# Usage:
#   AWS_PROFILE=<client-bootstrap> infra/scripts/onboard-site.sh <env-dir-name>
#   CONFIRM_FRESH=1 AWS_PROFILE=<...> infra/scripts/onboard-site.sh <env>  # first run

set -euo pipefail

ENV_NAME="${1:?usage: onboard-site.sh <env-dir-name>}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_DIR="${SCRIPT_DIR}/../envs/${ENV_NAME}"
POLL_INTERVAL=30  # seconds between delegation checks
POLL_TIMEOUT=3600 # give up after 1h of waiting on the registrar

[ -d "${ENV_DIR}" ] || { echo "no such env: ${ENV_DIR}" >&2; exit 1; }
cd "${ENV_DIR}"

echo "==> terraform init"
terraform init -input=false >/dev/null

# Guardrail: an empty state means Terraform will CREATE everything. That's
# correct for a genuine first run, but on a RE-RUN it almost always means the
# state is lost or pointed at the wrong backend — and applying anyway would
# collide with existing resources AND silently create a DUPLICATE Route 53 zone
# (Route 53 allows same-name zones). So require explicit acknowledgement.
if [ -z "$(terraform state list 2>/dev/null)" ]; then
  case "${CONFIRM_FRESH:-}" in
    1 | true | yes)
      echo "==> empty state + CONFIRM_FRESH set — treating as a first-time provision"
      ;;
    *)
      cat >&2 <<EOF
REFUSING TO APPLY: Terraform state for '${ENV_NAME}' is empty.
  - FIRST time provisioning this env?  Re-run with CONFIRM_FRESH=1 (or pass
    confirm-fresh: true to the aws-provision-site action).
  - Provisioned it before?  Your state is missing or the backend in versions.tf
    is mis-pointed. Fix the backend first — applying now would recreate
    resources and create a duplicate Route 53 zone.
EOF
      exit 2
      ;;
  esac
fi

echo "==> creating hosted zone (if this env creates one)"
# No-op when create_hosted_zone = false (the resource has zero instances).
terraform apply -input=false -auto-approve \
  -target='module.site.aws_route53_zone.primary' \
  -target='module.site.aws_route53domains_registered_domain.this' >/dev/null 2>&1 || true

# Did we create a zone that still needs delegating?
ns_json="$(terraform output -json hosted_zone_name_servers 2>/dev/null || echo '[]')"
if [ "$(echo "${ns_json}" | tr -d '[:space:]')" = "[]" ]; then
  echo "==> no zone to delegate (existing zone, or DNS not managed). Applying."
  terraform apply -input=false -auto-approve
  echo "==> done."
  exit 0
fi

DOMAIN="$(terraform output -raw hosted_zone_name)"

echo
echo "==> Hosted zone created for ${DOMAIN}. Set these nameservers at the registrar:"
echo "${ns_json}" | tr -d '[:space:]' | tr ',' '\n' | sed 's/[]["]//g' | grep . | sed 's/^/      /'
echo

# If the domain is registered in Route 53, the registered_domain resource already
# set these — delegation will go live on its own. Otherwise this loop waits for a
# human to paste them at the registrar.
echo "==> waiting for delegation to go live (Ctrl-C to bail and finish later)…"
deadline=$(( $(date +%s) + POLL_TIMEOUT ))
until live="$(dig +short NS "${DOMAIN}" @1.1.1.1 2>/dev/null)"; [ -n "${live}" ] && echo "${live}" | grep -qi 'awsdns'; do
  if [ "$(date +%s)" -ge "${deadline}" ]; then
    echo "timed out waiting for delegation. Once it's live, re-run this script (it resumes)." >&2
    exit 1
  fi
  sleep "${POLL_INTERVAL}"
done

echo "==> delegation is live. Running full apply."
terraform apply -input=false -auto-approve
echo "==> done. Set the repo Variables from: terraform output"
