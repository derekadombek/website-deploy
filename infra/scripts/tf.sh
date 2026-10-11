#!/usr/bin/env bash
#
# Run Terraform for one client: inits against that client's state (from
# clients/<name>.yaml), then runs whatever you pass.
#
# Usage:
#   infra/scripts/tf.sh <client> plan
#   infra/scripts/tf.sh <client> apply
#   infra/scripts/tf.sh <client> output
#
# Auth: the active cloud creds (local) or the OIDC role (CI).

set -euo pipefail

NAME="${1:?usage: tf.sh <client> <terraform args…>}"; shift
source "$(dirname "${BASH_SOURCE[0]}")/lib/client.sh"

client_tf_init "${NAME}"
exec terraform "$@"
