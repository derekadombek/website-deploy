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
#   finish       (CI phase 2) — poll until the delegation is live, then full
#                apply.
#
# Delegation: a client with `delegate_from: <parent>` gets its NS record written
# into the parent's zone (delegate-ns.sh) — by the Provision workflow in CI, or
# here in `all` when DELEGATE_PROFILE names a profile for the parent's account.
# Otherwise you paste the nameservers at the registrar while this waits.
#
# For an existing-zone env, or one with registrar_in_route53 = true, there's
# nothing to delegate — it just applies.
#
# Auth: uses the active AWS creds/profile (local) or OIDC role (CI).
#
# Guardrail: with empty Terraform state it checks the account for this client's
# site (bucket, CloudFront, created zone) and refuses if any of it exists —
# that means lost/mis-pointed state, and applying would recreate resources +
# silently duplicate the Route 53 zone. Nothing found = genuine first run.
#
# Usage:
#   AWS_PROFILE=<bootstrap> onboard-site.sh [--phase all|create-zone|finish] <client>

set -euo pipefail

PHASE="all" ENV_NAME=""
while [ $# -gt 0 ]; do
  case "$1" in
    --phase) PHASE="$2"; shift 2;;
    -*) echo "unknown option: $1" >&2; exit 1;;
    *) ENV_NAME="$1"; shift;;
  esac
done
[ -n "${ENV_NAME}" ] || { echo "usage: onboard-site.sh [--phase all|create-zone|finish] <client>" >&2; exit 1; }

source "$(dirname "${BASH_SOURCE[0]}")/lib/client.sh"
POLL_INTERVAL=30  # seconds between delegation checks
POLL_TIMEOUT=3600 # give up after 1h of waiting on the registrar

# Empty state is right on a genuine first run, but on a re-run it means lost or
# mis-pointed state — applying would collide with the existing site AND silently
# duplicate the Route 53 zone (Route 53 allows same-name zones). So when state is
# empty, look in the account for this client's site; go ahead only if none of it
# is there.
# Sets FOUND. Runs in the main shell (not $(…)) so a failed AWS call aborts
# under set -e instead of silently reading as "nothing found".
existing_resources() {
  local acct bucket zone err
  FOUND=""
  acct="$(aws sts get-caller-identity --query Account --output text)"
  bucket="${ENV_NAME}-site-${acct}"

  # 404 = no such bucket; anything else (ours, or 403 someone else's) = taken.
  if err="$(aws s3api head-bucket --bucket "${bucket}" 2>&1)" || ! echo "${err}" | grep -q '404'; then
    FOUND+="  - S3 bucket ${bucket}\n"
  fi

  local dist
  dist="$(aws cloudfront list-distributions \
    --query "DistributionList.Items[?Origins.Items[?starts_with(DomainName, '${bucket}.s3.')]].Id" --output text)"
  [ -z "${dist}" ] || [ "${dist}" = "None" ] || FOUND+="  - CloudFront distribution ${dist}\n"

  # Only a zone this client would CREATE counts — an existing-zone client's zone
  # is supposed to be there.
  case "$(client_get "${ENV_NAME}" dns existing-zone)" in
    route53-registrar | external)
      zone="$(client_zone "${ENV_NAME}")"
      if [ -n "${zone}" ]; then
        local zid
        zid="$(aws route53 list-hosted-zones-by-name --dns-name "${zone}" --max-items 1 \
          --query "HostedZones[?Name=='${zone}.'] | [0].Id" --output text)"
        [ -z "${zid}" ] || [ "${zid}" = "None" ] || FOUND+="  - Route 53 zone ${zone} (${zid##*/})\n"
      fi
      ;;
  esac
}

check_fresh_or_refuse() {
  [ -n "$(terraform state list 2>/dev/null)" ] && return 0

  echo "==> Terraform state for '${ENV_NAME}' is empty — checking the account for an existing site"
  existing_resources
  if [ -z "${FOUND}" ]; then
    echo "==> nothing found — first-time provision"
    return 0
  fi
  cat >&2 <<EOF
REFUSING TO APPLY: Terraform state for '${ENV_NAME}' is empty, but its site
already exists in this account:
$(printf '%b' "${FOUND}")
The state is missing, or state_bucket/lock_table in clients/${ENV_NAME}.yaml point
at the wrong place. Applying now would collide with these and create a duplicate
Route 53 zone. Point the backend at the right state (or delete these by hand if
they're leftovers), then re-run.
EOF
  exit 2
}

create_zone() {
  echo "==> creating hosted zone (if this env creates one)"
  # The targeted apply is only for a zone that doesn't exist yet. Skip it otherwise: on an
  # older state with pending `moved` blocks (module.site → module.site[0], v1.8.0) Terraform
  # refuses any -target run, and the full apply in `finish` handles the moves.
  case "$(client_get "${ENV_NAME}" dns existing-zone)" in
    route53-registrar | external) ;;
    *) echo "    none: this client uses an existing zone" >&2; return 0 ;;
  esac
  if terraform state list 2>/dev/null | grep -qE 'aws_route53_zone\.(primary|app)(\[0\])?$'; then
    echo "    already in state, nothing to create" >&2
    return 0
  fi
  local targets=(-target='module.site[0].aws_route53_zone.primary' -target='module.site[0].aws_route53domains_registered_domain.this')
  [ "$(client_get "${ENV_NAME}" site true)" = "false" ] && targets=(-target='aws_route53_zone.app')
  # Output to stderr: the logs, not Provision's run summary (it tees stdout there).
  # Stop on failure: carrying on finds no zone, skips the delegation, and the full
  # apply then waits forever on certificate validation.
  terraform apply -input=false -auto-approve "${targets[@]}" >&2 || {
    echo "Creating the hosted zone failed (see above). Not continuing: without the zone the" >&2
    echo "NS delegation is skipped and the certificate would wait forever for DNS." >&2
    exit 1
  }
}

# The zone's name, from the client file (as infra/sites/aws computes it) — not
# `terraform output`: a targeted apply (create_zone) doesn't save outputs that
# don't depend on a targeted resource, so on a fresh state it isn't there.
zone_name() { client_zone "${ENV_NAME}"; }

zone_ns_json() { terraform output -json hosted_zone_name_servers 2>/dev/null || echo '[]'; }
has_zone() { [ "$(zone_ns_json | tr -d '[:space:]')" != "[]" ]; }

print_ns() {
  local domain; domain="$(zone_name)"
  echo
  echo "==> Hosted zone created for ${domain}. Set these nameservers at the registrar:"
  zone_ns_json | tr -d '[:space:]' | tr ',' '\n' | sed 's/[]["]//g' | grep . | sed 's/^/      /'
  echo
}

# True once public DNS for the zone answers with Route 53 nameservers.
delegation_live() {
  local domain live
  domain="$(zone_name)"
  live="$(dig +short NS "${domain}" @1.1.1.1 2>/dev/null || true)"
  echo "${live}" | grep -qi 'awsdns'
}

wait_for_delegation() {
  local domain; domain="$(zone_name)"
  echo "==> waiting for delegation of ${domain} to go live…"
  local deadline=$(( $(date +%s) + POLL_TIMEOUT ))
  until delegation_live; do
    if [ "$(date +%s)" -ge "${deadline}" ]; then
      echo "timed out waiting for delegation. Once it's live, re-run Provision (or --phase finish locally)." >&2
      exit 1
    fi
    sleep "${POLL_INTERVAL}"
  done
  echo "==> delegation is live."
}

full_apply() {
  echo "==> full apply"
  terraform apply -input=false -auto-approve
  if [ "$(client_get "${ENV_NAME}" site true)" = "false" ]; then
    echo "==> done. No site here: ship Onsyte with Deploy Onsyte (clients repo)."
    return
  fi
  echo "==> done. App repo deploy.yml (templates/client-repo/deploy.yml):"
  echo "      client-name: ${ENV_NAME}"
  echo "      aws-account-id: \"$(client_get "${ENV_NAME}" account_id)\""
  echo "      aws-region: $(client_get "${ENV_NAME}" region)"
}

echo "==> terraform init (${ENV_NAME})"
client_tf_init "${ENV_NAME}"
[ "$(client_get "${ENV_NAME}" provider)" = "aws" ] || { echo "onboard-site.sh only handles aws clients" >&2; exit 1; }

case "${PHASE}" in
  create-zone)
    check_fresh_or_refuse
    create_zone
    if has_zone && delegation_live; then
      echo "==> $(zone_name) is already delegated — nothing to do for DNS."
    elif has_zone; then
      print_ns
      if [ -n "$(client_get "${ENV_NAME}" delegate_from)" ]; then
        echo "==> delegate_from is set — the NS record is added in $(client_parent_zone "${ENV_NAME}") automatically."
      else
        echo "==> Set those NS at the registrar now — the apply waits (up to 1h) for them to go live."
      fi
    else
      echo "==> no zone to delegate (no domain, existing zone, or registrar_in_route53)."
    fi
    ;;
  finish)
    has_zone && wait_for_delegation
    full_apply
    ;;
  all)
    check_fresh_or_refuse
    create_zone
    if has_zone; then
      print_ns
      if [ -n "$(client_get "${ENV_NAME}" delegate_from)" ] && [ -n "${DELEGATE_PROFILE:-}" ]; then
        AWS_PROFILE="${DELEGATE_PROFILE}" "${LIB_DIR}/../delegate-ns.sh" upsert "${ENV_NAME}" \
          $(zone_ns_json | tr -d '[:space:]' | tr ',' '\n' | sed 's/[]["]//g' | grep .)
      fi
      wait_for_delegation
    fi
    full_apply
    ;;
  *)
    echo "unknown phase: ${PHASE} (use all|create-zone|finish)" >&2; exit 1
    ;;
esac
