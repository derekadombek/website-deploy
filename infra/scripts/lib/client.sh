# Shared helpers for reading clients/<name>.yaml and pointing Terraform at that
# client's state. Source it; don't run it.
#
# CLIENTS_DIR picks the folder the client files live in (default: clients/ in
# this repo), so they can sit in a separate private repo.
#
# Client files are flat `key: value` YAML, so plain sed reads them — no yq.

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${LIB_DIR}/../../.." && pwd)"
_dir="${CLIENTS_DIR:-${REPO_ROOT}/clients}"
CLIENTS_DIR="$(cd "${_dir}" 2>/dev/null && pwd)" || { echo "CLIENTS_DIR not found: ${_dir}" >&2; return 1; }
unset _dir
export CLIENTS_DIR

# client_get <name> <key> [default] — print a field (quotes + trailing comment stripped).
client_get() {
  local v
  v="$(sed -n "s/^$2:[[:space:]]*//p" "${CLIENTS_DIR}/$1.yaml" | head -1 |
    sed -e 's/[[:space:]]#.*$//' -e 's/[[:space:]]*$//' -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'$/\1/")"
  printf '%s' "${v:-${3:-}}"
}

# client_zone <name> — the Route 53 zone the client's records go in: hosted_zone,
# else the domain, else (site: false) just Onsyte's <onsyte_subdomain>.<domain>.
# infra/sites/aws computes the same thing (local.zone_name).
client_zone() {
  local fallback; fallback="$(client_get "$1" domain)"
  if [ "$(client_get "$1" site true)" = "false" ] && [ -n "$(client_get "$1" onsyte_subdomain)" ]; then
    fallback="$(client_get "$1" onsyte_subdomain).${fallback}"
  fi
  client_get "$1" hosted_zone "${fallback}"
}

# client_list [provider] — every client name (optionally only one provider's).
client_list() {
  local f n
  for f in "${CLIENTS_DIR}"/*.yaml; do
    n="$(basename "${f}" .yaml)"
    if [ -z "${1:-}" ] || [ "$(client_get "${n}" provider)" = "$1" ]; then echo "${n}"; fi
  done
  return 0
}

# client_check <name> — fail with a readable message if the file is missing or wrong.
client_check() {
  local name="$1" f="${CLIENTS_DIR}/$1.yaml" errs=""
  [ -f "${f}" ] || { echo "no client file: clients/${name}.yaml (have: $(client_list | tr '\n' ' '))" >&2; return 1; }
  echo "${name}" | grep -qE '^[a-z0-9][a-z0-9-]*$' || errs+="  name must be lowercase letters, digits, dashes\n"

  local provider; provider="$(client_get "${name}" provider)"
  [ -d "${REPO_ROOT}/infra/sites/${provider:-none}" ] || errs+="  provider '${provider}' has no infra/sites/<provider> root\n"

  if [ "${provider}" = "aws" ]; then
    case "$(client_get "${name}" state_lock dynamodb)" in
      dynamodb | both | s3) ;;
      *) errs+="  state_lock must be dynamodb, both or s3\n" ;;
    esac
    client_get "${name}" account_id | grep -qE '^[0-9]{12}$' || errs+="  account_id must be the 12-digit AWS account id (quoted)\n"
    [ -n "$(client_get "${name}" region)" ] || errs+="  region is required\n"
    local site; site="$(client_get "${name}" site true)"
    case "${site}" in
      true | false) ;;
      *) errs+="  site must be true or false\n" ;;
    esac
    if [ "${site}" != "false" ] || [ -n "$(client_get "${name}" app_repo)" ]; then
      client_get "${name}" app_repo | grep -qE '^[^/]+/[^/]+$' || errs+="  app_repo must be owner/name\n"
    fi
    if [ -n "$(client_get "${name}" domain)" ]; then
      case "$(client_get "${name}" dns existing-zone)" in
        existing-zone | route53-registrar | external) ;;
        *) errs+="  dns must be existing-zone, route53-registrar or external\n" ;;
      esac
    fi

    local onsyte; onsyte="$(client_get "${name}" onsyte_subdomain)"
    if [ -n "${onsyte}" ]; then
      echo "${onsyte}" | grep -qE '^[a-z0-9][a-z0-9-]*$' || errs+="  onsyte_subdomain must be one DNS label (letters, digits, dashes)\n"
      [ -n "$(client_get "${name}" domain)" ] || errs+="  onsyte_subdomain needs domain (Onsyte goes at <onsyte_subdomain>.<domain>)\n"
      case "${onsyte}.$(client_get "${name}" domain)" in
        "$(client_zone "${name}")" | *."$(client_zone "${name}")") ;;
        *) errs+="  hosted_zone must hold ${onsyte}.$(client_get "${name}" domain) (be it or a parent of it)\n" ;;
      esac
    fi

    # No site: the account only runs Onsyte, in its own zone (onsyte.<domain> by
    # default) — the client's site and DNS stay wherever they are.
    if [ "${site}" = "false" ]; then
      [ -n "${onsyte}" ] || errs+="  site: false needs onsyte_subdomain (there's nothing else to build)\n"
      case "$(client_get "${name}" dns existing-zone)" in
        existing-zone | external) ;;
        *) errs+="  site: false needs dns: external or existing-zone\n" ;;
      esac
    fi

    local parent; parent="$(client_get "${name}" delegate_from)"
    if [ -n "${parent}" ]; then
      local pzone; pzone="$(client_parent_zone "${name}")"
      [ -f "${CLIENTS_DIR}/${parent}.yaml" ] || errs+="  delegate_from: no client file clients/${parent}.yaml\n"
      [ "$(client_get "${name}" dns)" = "external" ] || errs+="  delegate_from needs dns: external (the zone is created here, delegated from ${parent})\n"
      case "$(client_zone "${name}")" in
        *."${pzone}") ;;
        *) errs+="  delegate_from: domain must be a subdomain of ${parent}'s zone (${pzone:-none})\n" ;;
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
  export TF_VAR_clients_dir="${CLIENTS_DIR}"

  if [ "${1:-}" = "-backend=false" ]; then
    # Separate data dir: a dir that's already been inited against real state
    # would still try to reach that backend.
    export TF_DATA_DIR=".terraform-validate"
    terraform init -input=false -backend=false >/dev/null
    return
  fi

  case "${provider}" in
    aws)
      # state_lock: dynamodb (the old table) → both (switching) → s3 (lockfile only).
      local table lock
      table="-backend-config=dynamodb_table=$(client_get "${name}" lock_table "${name}-tf-locks")"
      lock=("${table}")
      case "$(client_get "${name}" state_lock dynamodb)" in
        both) lock=("${table}" -backend-config=use_lockfile=true) ;;
        s3) lock=(-backend-config=use_lockfile=true) ;;
      esac
      terraform init -input=false -reconfigure \
        -backend-config="bucket=$(client_get "${name}" state_bucket "${name}-tf-state")" \
        -backend-config="key=sites/${name}/terraform.tfstate" \
        -backend-config="region=$(client_get "${name}" region)" \
        "${lock[@]}" \
        -backend-config="encrypt=true" >/dev/null
      ;;
  esac
}

# Role ARNs are predictable from the client file — no copying them around.
client_tf_role_arn() { echo "arn:aws:iam::$(client_get "$1" account_id):role/$1-terraform"; }
client_deploy_role_arn() { echo "arn:aws:iam::$(client_get "$1" account_id):role/$1-github-deploy"; }

# Subdomain delegation (delegate_from: <parent client>) — the parent client's
# account holds the zone the NS record goes in, and a <parent>-dns-delegation
# role (infra/access, delegation_zone_name) that's allowed to write it.
client_parent_zone() {
  local parent; parent="$(client_get "$1" delegate_from)"
  [ -n "${parent}" ] && [ -f "${CLIENTS_DIR}/${parent}.yaml" ] || return 0
  client_zone "${parent}"
}
client_delegation_role_arn() {
  local parent; parent="$(client_get "$1" delegate_from)"
  [ -n "${parent}" ] || return 0
  client_parent_role_arn "${parent}"
}
client_parent_role_arn() { echo "arn:aws:iam::$(client_get "$1" account_id):role/$1-dns-delegation"; }

# client_recorded_delegation <name> — "<parent> <record>" from the client's
# state (the sites stack's `delegation` output, written by the last apply), or
# nothing if it had none. Needs creds that can read the client's state.
client_recorded_delegation() {
  local out; out="$("${LIB_DIR}/../tf.sh" "$1" output -json)" || return 1
  jq -r '.delegation.value // {} | select((.parent // "") != "") | "\(.parent) \(.record)"' <<<"${out}"
}

# client_stale_delegation <name> — the recorded delegation if the client file no
# longer asks for exactly that one (delegate_from removed or changed, or the
# domain moved), so its NS record in the old parent zone should go.
client_stale_delegation() {
  local was now=""
  was="$(client_recorded_delegation "$1")" || return 1
  [ -n "$(client_get "$1" delegate_from)" ] &&
    now="$(client_get "$1" delegate_from) $(client_zone "$1")"
  [ -z "${was}" ] || [ "${was}" = "${now}" ] || echo "${was}"
}
client_plan_role_arn() { echo "arn:aws:iam::$(client_get "$1" account_id):role/$1-plan"; }

# client_dropdown_names — what every `client` dropdown lists: the CI-managed AWS
# clients (ci isn't false), sorted.
client_dropdown_names() {
  local c
  for c in $(client_list aws); do [ "$(client_get "${c}" ci true)" = "false" ] || echo "${c}"; done | sort
}

# client_dropdowns_check <workflows dir> — every workflow there with a `client`
# dropdown (workflow_dispatch input of type choice) must list exactly the
# CI-managed AWS clients (ci isn't false), plus optionally "all". Add a client's
# name to the dropdowns in the same PR as its file. Needs yq (on GitHub runners).
client_dropdowns_check() {
  local dir="$1" f want have errs=""
  want="$(client_dropdown_names)"
  for f in "${dir}"/*.yml "${dir}"/*.yaml; do
    [ -f "${f}" ] || continue
    [ "$(yq '.on.workflow_dispatch.inputs.client.type // ""' "${f}")" = "choice" ] || continue
    have="$(yq '.on.workflow_dispatch.inputs.client.options[]' "${f}" | grep -vx all | sort || true)"
    [ "${have}" = "${want}" ] ||
      errs+="  $(basename "${f}"): missing [$(comm -23 <(echo "${want}") <(echo "${have}") | xargs)] extra [$(comm -13 <(echo "${want}") <(echo "${have}") | xargs)]\n"
  done
  [ -z "${errs}" ] || { printf "client dropdowns don't match the CI-managed clients in clients/:\n${errs}" >&2; return 1; }
}

# client_dropdowns_sync <workflows dir> — rewrite every `client` dropdown to list
# exactly client_dropdown_names (keeping a leading "all" where a dropdown has one).
# Only the `- name` lines under that input's `options:` change; the rest of each
# file is left byte for byte. Prints the files it changed. Needs yq (to find them).
client_dropdowns_sync() {
  local dir="$1" f names tmp
  names="$(client_dropdown_names)"
  for f in "${dir}"/*.yml "${dir}"/*.yaml; do
    [ -f "${f}" ] || continue
    [ "$(yq '.on.workflow_dispatch.inputs.client.type // ""' "${f}")" = "choice" ] || continue
    local all="" opts
    # Read first: piping into grep -q fails under pipefail when grep stops early.
    opts="$(yq '.on.workflow_dispatch.inputs.client.options[]' "${f}")"
    if grep -qx all <<<"${opts}"; then all="all"; fi
    tmp="$(mktemp)"
    # In the `client:` input's block: replace the list after `options:`.
    NAMES="$({ [ -z "${all}" ] || echo all; echo "${names}"; })" awk '
      function indent(s) { match(s, /^ */); return RLENGTH }
      in_opts && /^ *- / && indent($0) > opts_indent { next }
      in_opts { in_opts = 0; in_client = 0 }
      /^ +client:[[:space:]]*$/ && !done { in_client = 1; client_indent = indent($0); print; next }
      in_client && indent($0) <= client_indent && $0 !~ /^[[:space:]]*$/ { in_client = 0 }
      in_client && /^ +options:[[:space:]]*$/ {
        print; opts_indent = indent($0); in_opts = 1; done = 1
        n = split(ENVIRON["NAMES"], list, "\n")
        pad = ""; for (i = 0; i < opts_indent + 2; i++) pad = pad " "
        for (i = 1; i <= n; i++) if (list[i] != "") print pad "- " list[i]
        next
      }
      { print }
    ' "${f}" > "${tmp}"
    if cmp -s "${tmp}" "${f}"; then rm -f "${tmp}"; else cat "${tmp}" > "${f}"; rm -f "${tmp}"; echo "${f}"; fi
  done
}
