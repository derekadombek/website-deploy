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
#     [--mgmt-repo <o/r>] [--branch <b>]

set -euo pipefail

PROJECT="" REGION="" DEPLOY_REPO="" MGMT_ENV="" STATE_BUCKET="" LOCK_TABLE=""
MGMT_REPO="" BRANCH=""

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
    *) echo "unknown option: $1" >&2; exit 1;;
  esac
done

for req in PROJECT REGION DEPLOY_REPO MGMT_ENV STATE_BUCKET LOCK_TABLE; do
  [ -n "${!req}" ] || { echo "--$(echo "$req" | tr 'A-Z_' 'a-z-') is required" >&2; exit 1; }
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ACCESS_DIR="${SCRIPT_DIR}/../access"

# 1. State backend (CLI — no Terraform state needed to create it).
"${SCRIPT_DIR}/bootstrap-backend.sh" "${STATE_BUCKET}" "${LOCK_TABLE}" "${REGION}"

# 2. Access Terraform, state stored in the bucket just created.
cd "${ACCESS_DIR}"
terraform init -input=false -reconfigure \
  -backend-config="bucket=${STATE_BUCKET}" \
  -backend-config="key=access/terraform.tfstate" \
  -backend-config="region=${REGION}" \
  -backend-config="dynamodb_table=${LOCK_TABLE}" \
  -backend-config="encrypt=true"

terraform apply -auto-approve -input=false \
  -var="aws_region=${REGION}" \
  -var="project_name=${PROJECT}" \
  -var="deploy_github_repo=${DEPLOY_REPO}" \
  -var="mgmt_environment=${MGMT_ENV}" \
  -var="tf_state_bucket=${STATE_BUCKET}" \
  -var="tf_lock_table=${LOCK_TABLE}" \
  ${MGMT_REPO:+-var="mgmt_github_repo=${MGMT_REPO}"} \
  ${BRANCH:+-var="github_branch=${BRANCH}"}

echo
echo "=== access granted — role ARNs ==="
terraform output
echo
echo "Next (you): create the site env (mgmt_environment=${MGMT_ENV}, create_iam=false),"
echo "register its GitHub Environment with the terraform_role_arn above, then provision."
