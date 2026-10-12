#!/usr/bin/env bash
#
# Grant access: stand up the trust foundation in an AWS account so this repo can
# manage it over OIDC. Creates the state backend (AWS CLI) then applies the
# access Terraform (OIDC provider + deploy role + management role) with state in
# that bucket — so there's no local state and nothing to bootstrap by hand.
#
# A CLIENT runs this once (via the aws-grant-access action, with their creds);
# afterwards you build their site over OIDC. Idempotent / re-runnable.
#
# Auth: uses the active AWS credentials (the client's privileged access).
#
# Usage:
#   grant-access.sh --project <p> --region <r> --deploy-repo <o/r> \
#     --mgmt-environment <env> --state-bucket <b> --lock-table <t> \
#     [--mgmt-repo <o/r>] [--branch <b>] [--delegation-zone <zone>]
#
#   --delegation-zone  also create <project>-dns-delegation, letting other clients
#                      delegate subdomains of this account's <zone> to themselves.

set -euo pipefail

PROJECT="" REGION="" DEPLOY_REPO="" MGMT_ENV="" STATE_BUCKET="" LOCK_TABLE=""
MGMT_REPO="" BRANCH="" DELEGATION_ZONE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --project) PROJECT="$2"; shift 2;;
    --region) REGION="$2"; shift 2;;
    --deploy-repo) DEPLOY_REPO="$2"; shift 2;;
    --mgmt-environment) MGMT_ENV="$2"; shift 2;;
    --state-bucket) STATE_BUCKET="$2"; shift 2;;
    --lock-table) LOCK_TABLE="$2"; shift 2;;
    --mgmt-repo) MGMT_REPO="$2"; shift 2;;
    --branch) BRANCH="$2"; shift 2;;
    --delegation-zone) DELEGATION_ZONE="$2"; shift 2;;
    *) echo "unknown option: $1" >&2; exit 1;;
  esac
done

for req in PROJECT REGION DEPLOY_REPO MGMT_ENV STATE_BUCKET LOCK_TABLE; do
  [ -n "${!req}" ] || { echo "--$(echo "$req" | tr 'A-Z_' 'a-z-') is required" >&2; exit 1; }
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ACCESS_DIR="${SCRIPT_DIR}/../access"

# 1. State backend (CLI — creates the bucket + lock table if they're missing).
"${SCRIPT_DIR}/bootstrap-backend.sh" "${STATE_BUCKET}" "${LOCK_TABLE}" "${REGION}"

# 2. Access Terraform, state stored in the bucket just created.
cd "${ACCESS_DIR}"
terraform init -input=false -reconfigure \
  -backend-config="bucket=${STATE_BUCKET}" \
  -backend-config="key=access/terraform.tfstate" \
  -backend-config="region=${REGION}" \
  -backend-config="dynamodb_table=${LOCK_TABLE}" \
  -backend-config="encrypt=true"

# 3. The account can only have ONE GitHub OIDC provider. Create it unless the
#    account already has one; if it does, reuse it — except when it's this
#    access stack's own (in state), which must stay managed here.
OIDC_URL="token.actions.githubusercontent.com"
# Match the CREATED provider only — not the data-source lookup
# (module.github_oidc.data.aws_iam_openid_connect_provider…) a reusing stack has.
if terraform state list 2>/dev/null | grep -qx 'module.github_oidc.aws_iam_openid_connect_provider.github\[0\]'; then
  CREATE_OIDC=true
  echo "OIDC provider: managed by this access stack — keeping it"
elif aws iam list-open-id-connect-providers --query 'OpenIDConnectProviderList[].Arn' --output text | tr '\t' '\n' | grep -q "/${OIDC_URL}\$"; then
  CREATE_OIDC=false
  echo "OIDC provider: already exists in this account — reusing it"
else
  CREATE_OIDC=true
  echo "OIDC provider: none yet — creating it"
fi

terraform apply -auto-approve -input=false \
  -var="create_oidc_provider=${CREATE_OIDC}" \
  -var="aws_region=${REGION}" \
  -var="project_name=${PROJECT}" \
  -var="deploy_github_repo=${DEPLOY_REPO}" \
  -var="mgmt_environment=${MGMT_ENV}" \
  -var="tf_state_bucket=${STATE_BUCKET}" \
  -var="tf_lock_table=${LOCK_TABLE}" \
  ${MGMT_REPO:+-var="mgmt_github_repo=${MGMT_REPO}"} \
  ${BRANCH:+-var="github_branch=${BRANCH}"} \
  ${DELEGATION_ZONE:+-var="delegation_zone_name=${DELEGATION_ZONE}"}

echo
echo "=== access granted — role ARNs ==="
terraform output
echo
echo "Next: send the site owner this account id — $(aws sts get-caller-identity --query Account --output text)."
echo "They add clients/${MGMT_ENV}.yaml with it and merge, then run Provision."
