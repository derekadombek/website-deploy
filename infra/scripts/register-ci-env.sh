#!/usr/bin/env bash
#
# Put an env under CI management: create its GitHub Environment (named the same
# as the env dir), set the scoped AWS_TF_ROLE_ARN + AWS_REGION variables from
# terraform output, and add a required reviewer. Run once per env, after it's
# been provisioned (so terraform_role_arn exists).
#
# Auth: needs gh logged in (manages GitHub) AND AWS creds for `terraform output`.
#
# Usage:
#   infra/scripts/register-ci-env.sh <env-dir-name> [reviewer-login]
#     reviewer-login defaults to the authenticated gh user.

set -euo pipefail

ENV_NAME="${1:?usage: register-ci-env.sh <env-dir-name> [reviewer-login]}"
REVIEWER="${2:-}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_DIR="${SCRIPT_DIR}/../envs/${ENV_NAME}"
[ -d "${ENV_DIR}" ] || { echo "no such env: ${ENV_DIR}" >&2; exit 1; }

REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner)"

cd "${ENV_DIR}"
terraform init -input=false >/dev/null
ROLE_ARN="$(terraform output -raw terraform_role_arn)"
# Region isn't a TF output; read the default provider's region from versions.tf.
REGION="$(grep -m1 -E '^\s*region\s*=\s*"' versions.tf | sed -E 's/.*"([^"]+)".*/\1/')"

if [ -n "${REVIEWER}" ]; then
  RID="$(gh api "users/${REVIEWER}" --jq .id)"
else
  RID="$(gh api user --jq .id)"
fi

echo "Registering CI environment '${ENV_NAME}' in ${REPO}"
echo "  role=${ROLE_ARN}"
echo "  region=${REGION}  reviewer-id=${RID}"

gh api -X PUT "repos/${REPO}/environments/${ENV_NAME}" --input - <<JSON >/dev/null
{
  "wait_timer": 0,
  "prevent_self_review": false,
  "reviewers": [ { "type": "User", "id": ${RID} } ],
  "deployment_branch_policy": null
}
JSON

gh variable set AWS_TF_ROLE_ARN --env "${ENV_NAME}" --repo "${REPO}" --body "${ROLE_ARN}"
gh variable set AWS_REGION --env "${ENV_NAME}" --repo "${REPO}" --body "${REGION}"

echo "done — '${ENV_NAME}' is now CI-managed (gated by its own approval)."
