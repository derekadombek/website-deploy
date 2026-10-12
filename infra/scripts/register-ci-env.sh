#!/usr/bin/env bash
#
# Put a client under CI management: create its GitHub Environment (named the
# same as the client), set the scoped AWS_TF_ROLE_ARN + AWS_REGION variables, and
# add a required reviewer (when the repo's GitHub plan allows it; otherwise it
# warns). The role ARN + region come from clients/<name>.yaml — nothing to copy
# from the aws-grant-access output. Re-runnable.
#
# Auth: needs gh logged in with admin on this (the management) repo. No AWS
# creds or terraform needed.
#
# Usage:
#   infra/scripts/register-ci-env.sh <client> [reviewer-login]
#     reviewer-login defaults to the authenticated gh user.

set -euo pipefail

ENV_NAME="${1:?usage: register-ci-env.sh <client> [reviewer]}"
REVIEWER="${2:-}"

source "$(dirname "${BASH_SOURCE[0]}")/lib/client.sh"
client_check "${ENV_NAME}"
ROLE_ARN="$(client_tf_role_arn "${ENV_NAME}")"
REGION="$(client_get "${ENV_NAME}" region)"

# In CI: the repo running the workflow (the clients repo, not the package checkout).
REPO="${GITHUB_REPOSITORY:-$(gh repo view --json nameWithOwner -q .nameWithOwner)}"

if [ -n "${REVIEWER}" ]; then
  RID="$(gh api "users/${REVIEWER}" --jq .id)"
else
  RID="$(gh api user --jq .id)"
fi

echo "Registering CI environment '${ENV_NAME}' in ${REPO}"
echo "  role=${ROLE_ARN}"
echo "  region=${REGION}  reviewer-id=${RID}"

# put_env <json> — create/update the environment; prints gh's error on failure.
put_env() { gh api -X PUT "repos/${REPO}/environments/${ENV_NAME}" --input - <<<"$1" 2>&1 >/dev/null; }

GATE="gated by its own approval"
if ! err="$(put_env '{"wait_timer": 0, "prevent_self_review": false,
  "reviewers": [ { "type": "User", "id": '"${RID}"' } ], "deployment_branch_policy": null}')"; then
  # Private repos only get required reviewers on GitHub Enterprise. Without one the
  # environment still works (OIDC login), but applies don't wait for an approval.
  case "${err}" in
    *"billing plan"*) ;;
    *) echo "${err}" >&2; exit 1 ;;
  esac
  put_env '{"deployment_branch_policy": null}' >&2 # no wait timer either: also a paid rule
  GATE="NO APPROVAL GATE: this repo's plan doesn't allow required reviewers"
  msg="'${ENV_NAME}': no required reviewer (not available on this repo's GitHub plan) — applies won't wait for approval."
  if [ -n "${GITHUB_ACTIONS:-}" ]; then echo "::warning::${msg}"; else echo "WARNING: ${msg}" >&2; fi
fi

gh variable set AWS_TF_ROLE_ARN --env "${ENV_NAME}" --repo "${REPO}" --body "${ROLE_ARN}"
gh variable set AWS_REGION --env "${ENV_NAME}" --repo "${REPO}" --body "${REGION}"

echo "done — '${ENV_NAME}' is now CI-managed (${GATE})."
