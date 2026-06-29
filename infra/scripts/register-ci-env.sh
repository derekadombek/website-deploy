#!/usr/bin/env bash
#
# Put an env under CI management: create its GitHub Environment (named the same
# as the env dir), set the scoped AWS_TF_ROLE_ARN + AWS_REGION variables, and
# add a required reviewer. Run once per env, after aws-grant-access has created
# the roles — pass the terraform role ARN + region it printed.
#
# Auth: needs gh logged in with admin on this (the management) repo. No AWS
# creds or terraform needed — the role ARN + region are passed in.
#
# Usage:
#   infra/scripts/register-ci-env.sh <env-dir-name> <terraform-role-arn> <aws-region> [reviewer-login]
#     reviewer-login defaults to the authenticated gh user.

set -euo pipefail

ENV_NAME="${1:?usage: register-ci-env.sh <env> <terraform-role-arn> <aws-region> [reviewer]}"
ROLE_ARN="${2:?usage: register-ci-env.sh <env> <terraform-role-arn> <aws-region> [reviewer]}"
REGION="${3:?usage: register-ci-env.sh <env> <terraform-role-arn> <aws-region> [reviewer]}"
REVIEWER="${4:-}"

# The GitHub Environment is independent of the Terraform config, so this can run
# any time (e.g. straight after aws-grant-access, before the env PR merges). We
# only warn — not block — if the matching env dir doesn't exist yet, since the
# name must eventually match it (terraform.yml keys off the env dir name).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_DIR="${SCRIPT_DIR}/../envs/${ENV_NAME}"
[ -d "${ENV_DIR}" ] || echo "warning: no env dir 'infra/envs/${ENV_NAME}' yet — make sure '${ENV_NAME}' matches the env dir name terraform.yml will use." >&2

REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner)"

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
