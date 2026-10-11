# Shared helpers for reading clients/<name>.yaml and pointing Terraform at that
# client's state. Source it; don't run it.
#
# Client files are flat `key: value` YAML, so plain sed reads them — no yq.

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${LIB_DIR}/../../.." && pwd)"

# client_get <name> <key> [default] — print a field (quotes + trailing comment stripped).
client_get() {
  local v
  v="$(sed -n "s/^$2:[[:space:]]*//p" "${REPO_ROOT}/clients/$1.yaml" | head -1 |
    sed -e 's/[[:space:]]#.*$//' -e 's/[[:space:]]*$//' -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'$/\1/")"
  printf '%s' "${v:-${3:-}}"
}

# client_list [provider] — every client name (optionally only one provider's).
client_list() {
  local f n
  for f in "${REPO_ROOT}"/clients/*.yaml; do
    n="$(basename "${f}" .yaml)"
    if [ -z "${1:-}" ] || [ "$(client_get "${n}" provider)" = "$1" ]; then echo "${n}"; fi
  done
  return 0
}

# client_check <name> — fail with a readable message if the file is missing or wrong.
client_check() {
  local name="$1" f="${REPO_ROOT}/clients/$1.yaml" errs=""
  [ -f "${f}" ] || { echo "no client file: clients/${name}.yaml (have: $(client_list | tr '\n' ' '))" >&2; return 1; }
  echo "${name}" | grep -qE '^[a-z0-9][a-z0-9-]*$' || errs+="  name must be lowercase letters, digits, dashes\n"

  local provider; provider="$(client_get "${name}" provider)"
  [ -d "${REPO_ROOT}/infra/sites/${provider:-none}" ] || errs+="  provider '${provider}' has no infra/sites/<provider> root\n"

  if [ "${provider}" = "aws" ]; then
    client_get "${name}" account_id | grep -qE '^[0-9]{12}$' || errs+="  account_id must be the 12-digit AWS account id (quoted)\n"
    [ -n "$(client_get "${name}" region)" ] || errs+="  region is required\n"
    client_get "${name}" app_repo | grep -qE '^[^/]+/[^/]+$' || errs+="  app_repo must be owner/name\n"
    if [ -n "$(client_get "${name}" domain)" ]; then
      case "$(client_get "${name}" dns existing-zone)" in
        existing-zone | route53-registrar | external) ;;
        *) errs+="  dns must be existing-zone, route53-registrar or external\n" ;;
      esac
    fi
  fi

  [ -z "${errs}" ] || { printf "clients/%s.yaml is invalid:\n${errs}" "${name}" >&2; return 1; }
}

# client_tf_init <name> [-backend=false] — cd into the client's provider root
# and init it against that client's state. Each client gets its own .terraform
# data dir so switching clients never reuses another client's backend.
client_tf_init() {
  local name="$1"; shift
  client_check "${name}"
  local provider; provider="$(client_get "${name}" provider)"

  cd "${REPO_ROOT}/infra/sites/${provider}"
  export TF_DATA_DIR=".terraform-${name}"
  export TF_VAR_client="${name}"

  if [ "${1:-}" = "-backend=false" ]; then
    # Separate data dir: a dir that's already been inited against real state
    # would still try to reach that backend.
    export TF_DATA_DIR=".terraform-validate"
    terraform init -input=false -backend=false >/dev/null
    return
  fi

  case "${provider}" in
    aws)
      terraform init -input=false -reconfigure \
        -backend-config="bucket=$(client_get "${name}" state_bucket "${name}-tf-state")" \
        -backend-config="key=sites/${name}/terraform.tfstate" \
        -backend-config="region=$(client_get "${name}" region)" \
        -backend-config="dynamodb_table=$(client_get "${name}" lock_table "${name}-tf-locks")" \
        -backend-config="encrypt=true" >/dev/null
      ;;
  esac
}

# Role ARNs are predictable from the client file — no copying them around.
client_tf_role_arn() { echo "arn:aws:iam::$(client_get "$1" account_id):role/$1-terraform"; }
client_deploy_role_arn() { echo "arn:aws:iam::$(client_get "$1" account_id):role/$1-github-deploy"; }
