#!/usr/bin/env bash
#
# Add/remove the NS record that delegates a client's subdomain zone from its
# parent zone (client file: delegate_from: <parent client>). E.g. for a client
# at shop.acme.com, writes `shop.acme.com NS …` into client acme's acme.com zone.
#
# Auth: credentials for the PARENT account — in CI the <parent>-dns-delegation
# role (NS records only), locally any profile with Route 53 access there.
#
# Usage:
#   delegate-ns.sh upsert <client> <ns1> <ns2> [<ns3> <ns4>]   # idempotent
#   delegate-ns.sh delete <client>                             # no-op if absent
#   delegate-ns.sh delete-record <parent client> <record>      # no-op if absent
#
# delete-record removes a record the client file no longer describes (its
# delegate_from was removed or changed) — the values come from the client's
# state; see client_stale_delegation.

set -euo pipefail

usage="usage: delegate-ns.sh upsert|delete <client> [ns…] | delete-record <parent> <record>"
ACTION="${1:?${usage}}"
NAME="${2:?${usage}}"
shift 2

source "$(dirname "${BASH_SOURCE[0]}")/lib/client.sh"
if [ "${ACTION}" = "delete-record" ]; then
  PARENT="${NAME}"
  RECORD="${1:?${usage}}"
  [ -f "${CLIENTS_DIR}/${PARENT}.yaml" ] || { echo "no client file clients/${PARENT}.yaml for the parent zone" >&2; exit 1; }
  PARENT_ZONE="$(client_get "${PARENT}" hosted_zone "$(client_get "${PARENT}" domain)")"
  case "${RECORD}" in
    *."${PARENT_ZONE}") ;;
    *) echo "${RECORD} isn't a subdomain of ${PARENT_ZONE} — refusing to touch it" >&2; exit 1 ;;
  esac
  ACTION=delete
else
  client_check "${NAME}"
  PARENT_ZONE="$(client_parent_zone "${NAME}")"
  [ -n "${PARENT_ZONE}" ] || { echo "${NAME} has no delegate_from — nothing to delegate" >&2; exit 1; }
  RECORD="$(client_get "${NAME}" hosted_zone "$(client_get "${NAME}" domain)")"
fi

ZONE_ID="$(aws route53 list-hosted-zones-by-name --dns-name "${PARENT_ZONE}" --max-items 1 \
  --query "HostedZones[?Name=='${PARENT_ZONE}.'] | [0].Id" --output text)"
[ -n "${ZONE_ID}" ] && [ "${ZONE_ID}" != "None" ] || { echo "parent zone ${PARENT_ZONE} not found in this account" >&2; exit 1; }
ZONE_ID="${ZONE_ID##*/}"

change() { # change <ACTION> <resource-record-set JSON>
  local id
  id="$(aws route53 change-resource-record-sets --hosted-zone-id "${ZONE_ID}" \
    --change-batch "{\"Changes\":[{\"Action\":\"$1\",\"ResourceRecordSet\":$2}]}" \
    --query ChangeInfo.Id --output text)"
  aws route53 wait resource-record-sets-changed --id "${id}"
}

case "${ACTION}" in
  upsert)
    [ $# -ge 2 ] || { echo "upsert needs the zone's nameservers" >&2; exit 1; }
    records="$(printf '{"Value":"%s"},' "$@")"
    echo "==> ${RECORD} NS → $* (in ${PARENT_ZONE})"
    change UPSERT "{\"Name\":\"${RECORD}.\",\"Type\":\"NS\",\"TTL\":300,\"ResourceRecords\":[${records%,}]}"
    echo "==> delegation record set"
    ;;
  delete)
    # DELETE must match the current record exactly, so read it first.
    current="$(aws route53 list-resource-record-sets --hosted-zone-id "${ZONE_ID}" \
      --start-record-name "${RECORD}." --start-record-type NS --max-items 1 \
      --query "ResourceRecordSets[?Name=='${RECORD}.' && Type=='NS'] | [0]" --output json)"
    if [ "${current}" = "null" ] || [ -z "${current}" ]; then
      echo "==> no NS record for ${RECORD} in ${PARENT_ZONE} — nothing to delete"
    else
      echo "==> deleting ${RECORD} NS from ${PARENT_ZONE}"
      change DELETE "${current}"
      echo "==> delegation record removed"
    fi
    ;;
  *) echo "unknown action: ${ACTION} (use upsert|delete)" >&2; exit 1 ;;
esac
