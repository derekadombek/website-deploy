#!/usr/bin/env bash
#
# Print a client's One-click Connect AWS link: a CloudFormation quick-create link
# for infra/onboarding/connect-aws.yaml, pre-filled with their client name and an
# expiry date. Send it to the client; they sign in to their AWS console, open it,
# tick "I acknowledge that AWS CloudFormation might create IAM resources with custom
# names" and click Create stack, then send back their account id.
#
# Needs no AWS credentials. The template version must already be published
# (publish-onboarding-template.sh <version>).
#
# Usage:
#   onboarding-link.sh --client <name> [--region <r>] [--days <n>] [--version vX.Y.Z]
#
#   --client   the client name: their clients/<name>.yaml and GitHub environment
#              (the client file can come later, once you have their account id)
#   --region   where the stack goes; use the client file's region (default us-west-2)
#   --days     how long the link works (default 7)
#   --version  published template version (default: the newest vX.Y.Z tag up to
#              this checkout whose template is published)

set -euo pipefail

TEMPLATE_BUCKET="${TEMPLATE_BUCKET:-website-deploy-templates-722647055695}"

CLIENT="" REGION="us-west-2" DAYS=7 VERSION=""
while [ $# -gt 0 ]; do
  case "$1" in
    --client) CLIENT="$2"; shift 2;;
    --region) REGION="$2"; shift 2;;
    --days) DAYS="$2"; shift 2;;
    --version) VERSION="$2"; shift 2;;
    *) echo "unknown option: $1" >&2; exit 1;;
  esac
done

[ -n "${CLIENT}" ] || { echo "--client is required" >&2; exit 1; }
[[ "${CLIENT}" =~ ^[a-z0-9][a-z0-9-]{0,40}[a-z0-9]$ ]] \
  || { echo "--client: lowercase letters, numbers and dashes only" >&2; exit 1; }
[[ "${DAYS}" =~ ^[1-9][0-9]?$ ]] || { echo "--days: 1 to 99" >&2; exit 1; }

template_url() { echo "https://${TEMPLATE_BUCKET}.s3.amazonaws.com/connect-aws/$1.yaml"; }

# Not every release publishes the template (it rarely changes), so take the
# newest tag that has one. Only tags up to HEAD: never a template newer than
# the Onboard workflow running alongside it.
if [ -z "${VERSION}" ]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  tags="$(git -C "${SCRIPT_DIR}" tag --list 'v*.*.*' --merged HEAD --sort=-v:refname)"
  [ -n "${tags}" ] || { echo "no vX.Y.Z tag found; pass --version" >&2; exit 1; }
  for t in ${tags}; do
    if curl -fsI -o /dev/null "$(template_url "${t}")"; then VERSION="${t}"; break; fi
  done
  [ -n "${VERSION}" ] || { echo "no published template for any tag up to $(echo "${tags}" | head -1); publish one: infra/scripts/publish-onboarding-template.sh <version>" >&2; exit 1; }
fi

# Midnight UTC, DAYS days from today (BSD date on macOS, GNU date on Linux).
EXPIRES="$(date -u -v+"${DAYS}"d +%Y-%m-%dT00:00:00Z 2>/dev/null || date -u -d "+${DAYS} days" +%Y-%m-%dT00:00:00Z)"

TEMPLATE_URL="$(template_url "${VERSION}")"

# Fail now rather than hand the client a link that errors.
if ! curl -fsI -o /dev/null "${TEMPLATE_URL}"; then
  echo "template ${VERSION} isn't published (${TEMPLATE_URL})" >&2
  echo "publish it first: infra/scripts/publish-onboarding-template.sh ${VERSION}" >&2
  exit 1
fi

urlencode() { python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$1"; }

echo "Client:   ${CLIENT}"
echo "Region:   ${REGION}"
echo "Template: ${VERSION}"
echo "Expires:  ${EXPIRES}"
echo
echo "https://${REGION}.console.aws.amazon.com/cloudformation/home?region=${REGION}#/stacks/quickcreate?templateURL=$(urlencode "${TEMPLATE_URL}")&stackName=${CLIENT}-onboarding&param_ClientName=${CLIENT}&param_ExpiresAt=$(urlencode "${EXPIRES}")"
