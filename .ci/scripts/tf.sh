#!/usr/bin/env bash
# Shared OpenTofu steps for CI.
#
# GitLab CI and GitHub Actions both call this script, so the two platforms run
# the same steps. The platform YAML only picks the command, sets DEPLOYMENT and
# handles artifacts. You can also run it on your own machine (bash 4 or newer).
#
# Usage:
#   tf.sh validate       Check formatting, run tofu validate and shellcheck.
#   tf.sh plan           Write deployments/$DEPLOYMENT.out, the lock file copy
#                        deployments/$DEPLOYMENT.lock.hcl and the change marker
#                        deployments/$DEPLOYMENT.changes.
#   tf.sh apply          Apply deployments/$DEPLOYMENT.out.
#   tf.sh destroy-plan   Write deployments/$DEPLOYMENT-destroy.out and the lock
#                        file copy deployments/$DEPLOYMENT-destroy.lock.hcl.
#   tf.sh destroy        Apply deployments/$DEPLOYMENT-destroy.out.
#   tf.sh matrix         Print the deployment list per tier for GitHub Actions.
#
# Inputs (environment variables):
#   TF_BIN                       The OpenTofu or Terraform command to run.
#                                Default: tofu. Set it to terraform to use
#                                Terraform instead.
#   DEPLOYMENT                   Config file name without ".yaml", for example
#                                develop-a1b2c3d4. Required by plan, apply,
#                                destroy-plan and destroy.
#   ONLY_DEPLOYMENT              Optional, matrix only. Print only this
#                                deployment. Every other tier is "[]".
#   PRINT_OIDC_CLAIMS            "true" (default) prints the claims of the CI
#                                job's OIDC token when Entra ID rejects it. In
#                                CI, the Azure identity check always runs. On
#                                your own machine, "false" skips the identity
#                                check.
#   GITLAB_CI                    Set by GitLab. Turns on GitLab auth mode.
#   GITLAB_OIDC_TOKEN            JWT that GitLab makes for the job (GitLab only).
#   GITHUB_ACTIONS               Set by GitHub. Turns on GitHub auth mode.
#   ACTIONS_ID_TOKEN_REQUEST_URL, ACTIONS_ID_TOKEN_REQUEST_TOKEN
#                                Set by GitHub when the job has the
#                                "id-token: write" permission (GitHub only).
#                                OpenTofu uses them to get OIDC tokens.
#   GITHUB_STEP_SUMMARY          Set by GitHub Actions. When set, plan and
#                                destroy-plan write a summary to it.
#
# Auth mode:
#   GitLab CI       OpenTofu trades the job JWT (GITLAB_OIDC_TOKEN) for an
#                   Entra ID token for ci.azure_client_id.
#   GitHub Actions  OpenTofu asks GitHub for OIDC tokens itself and trades
#                   them for Entra ID tokens for ci.azure_client_id. No
#                   azure/login step is needed.
#   Your machine    Your Azure CLI login (az login).
# In CI, tf.sh unsets other Azure credentials first, so that OpenTofu cannot
# use some other identity. Then it checks with curl and jq that the token
# trade works and that the identity can read azure.subscription_id. On your
# machine, it checks your az login instead (if the az CLI is installed).
#
# A deployment is one file in deployments/configs/. The file name, the
# workspace name and DEPLOYMENT are the same value:
# <env>-<deployment_id>. This script reads env, deployment_id,
# azure.location, azure.subscription_id, azure.tenant_id and
# ci.azure_client_id from that file with yq (mikefarah yq 4.18 or newer).
# In CI, the script also needs curl and jq.

# This check must run before any bash 4 feature. macOS ships bash 3.2 as
# /bin/bash, which has no mapfile and no associative arrays.
if ((BASH_VERSINFO[0] < 4)); then
  echo "Error: tf.sh needs bash 4 or newer (found ${BASH_VERSION:-no bash}). On macOS, run 'brew install bash' (or install bash 4 or newer with your package manager) and make sure the new bash is first on PATH." >&2
  exit 1
fi

set -euo pipefail

# Find the repo root from the script location, so the script works from any
# working directory and on any platform.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DEPLOYMENTS_DIR="$REPO_ROOT/deployments"
CONFIGS_DIR="$DEPLOYMENTS_DIR/configs"
BACKENDS_DIR="$DEPLOYMENTS_DIR/backends"

# Tiers in pipeline order. A config's env value must be one of these.
# This is a default. To change it, see "Change the tiers" in README.md. The
# CI stages and jobs must change together with this list.
TIERS=(develop stage prod)

# Oldest mikefarah yq that runs the expressions in this script. Before 4.18,
# yq has no default command, so `yq '<expression>' file` fails.
YQ_MIN_MAJOR=4
YQ_MIN_MINOR=18

# GitHub keeps step summaries under 1 MiB. Cut the plan text well before that.
SUMMARY_MAX_BYTES=400000

# The command that runs every OpenTofu step. Set TF_BIN=terraform to use
# Terraform instead. Both read the same code and the same TF_* variables.
TF_BIN="${TF_BIN:-tofu}"

# Tell OpenTofu it runs without a person at the keyboard: shorter output and
# no "what to do next" hints. CHECKPOINT_DISABLE matters only for Terraform:
# it stops calls to the HashiCorp version check service.
export TF_IN_AUTOMATION=1
export CHECKPOINT_DISABLE=1

# Azure public cloud endpoints. Other clouds are not supported.
ENTRA_LOGIN_URL="https://login.microsoftonline.com"
ARM_URL="https://management.azure.com"
# The audience that Entra ID expects in a CI OIDC token. Each federated
# identity credential must list it.
OIDC_TOKEN_AUDIENCE="api://AzureADTokenExchange"

# Subscription IDs, tenant IDs and client IDs are GUIDs.
GUID_REGEX='^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'

RED='\033[0;31m'
YELLOW='\033[1;33m'
RESET='\033[0m'

usage() {
  echo "Usage: $(basename "$0") <validate|plan|apply|destroy-plan|destroy|matrix>" >&2
}

# Print a red error to stderr. Use fail to also stop the script.
error() {
  printf "${RED}Error: %s${RESET}\n" "$*" >&2
}

fail() {
  error "$@"
  exit 1
}

require_cmd() {
  local cmd="$1" hint="$2"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    fail "'$cmd' is not installed or not on PATH. $hint"
  fi
}

require_yq() {
  local need="$YQ_MIN_MAJOR.$YQ_MIN_MINOR"
  require_cmd yq "Install mikefarah yq $need or newer (https://github.com/mikefarah/yq). This script reads deployment configs with it."
  local version_text ver major minor
  version_text="$(yq --version 2>&1 || true)"
  if ! grep -q 'mikefarah' <<<"$version_text"; then
    fail "The 'yq' on PATH is not mikefarah yq. tf.sh needs mikefarah yq $need or newer. Install it from https://github.com/mikefarah/yq."
  fi
  ver="$(grep -Eo '[0-9]+\.[0-9]+(\.[0-9]+)?' <<<"$version_text" | head -n 1 || true)"
  major="${ver%%.*}"
  minor="${ver#*.}"
  minor="${minor%%.*}"
  if [[ ! "$major" =~ ^[0-9]+$ || ! "$minor" =~ ^[0-9]+$ ]] ||
    ((major != YQ_MIN_MAJOR || minor < YQ_MIN_MINOR)); then
    fail "tf.sh needs mikefarah yq v$YQ_MIN_MAJOR, version $need or newer (found ${ver:-an unknown version}). Install it from https://github.com/mikefarah/yq."
  fi
}

# Check that the TF_BIN command (tofu by default) is installed.
require_tf() {
  case "$TF_BIN" in
    tofu) require_cmd "$TF_BIN" "Install OpenTofu (https://opentofu.org/docs/intro/install/), or use a CI image that has it. To use Terraform instead, set TF_BIN=terraform." ;;
    terraform) require_cmd "$TF_BIN" "Install Terraform, or unset TF_BIN to use OpenTofu." ;;
    *) require_cmd "$TF_BIN" "TF_BIN must name the tofu or terraform command." ;;
  esac
}

# ─────────────────────────────────────────────────────────────────────────────
# Deployment config

# Read the fields this script needs from one config file into cfg_* globals.
# A missing or null field becomes an empty string. The *_style globals hold
# the YAML quote style of a field: "double" or "single" when it is quoted,
# empty when it is not.
read_config() {
  local file="$1" fields
  if ! fields="$(yq '.env // "", .deployment_id // "", .azure.location // "", .azure.subscription_id // "", .azure.tenant_id // "", .ci.azure_client_id // "", (.env | style), (.deployment_id | style)' "$file")"; then
    # yq prints its own error above this line.
    error "yq could not read ${file#"$REPO_ROOT"/}. See the yq error above."
    return 1
  fi
  local -a values
  mapfile -t values <<<"$fields"
  cfg_env="${values[0]:-}"
  cfg_deployment_id="${values[1]:-}"
  cfg_location="${values[2]:-}"
  cfg_subscription_id="${values[3]:-}"
  cfg_tenant_id="${values[4]:-}"
  cfg_client_id="${values[5]:-}"
  cfg_env_style="${values[6]:-}"
  cfg_deployment_id_style="${values[7]:-}"
}

# True when YAML reads an unquoted value as a number, for example 12345678,
# 1234e567 or 1.5. OpenTofu's yamldecode then turns it into a number, and
# 1234e567 becomes a string of 571 digits.
looks_like_number() {
  [[ "$1" =~ ^[+-]?([0-9]+\.?[0-9]*|\.[0-9]+)([eE][+-]?[0-9]+)?$ ]]
}

# Check one config. Print every problem found, then return non-zero if there
# were any. Expects read_config to have run for the same file.
#   $1: deployment name (config file name without .yaml)
#   $2: config file path
validate_config() {
  local name="$1" file="$2" ok=true rel
  rel="${file#"$REPO_ROOT"/}"

  local field value
  for field in env deployment_id azure.location azure.subscription_id azure.tenant_id ci.azure_client_id; do
    case "$field" in
      env) value="$cfg_env" ;;
      deployment_id) value="$cfg_deployment_id" ;;
      azure.location) value="$cfg_location" ;;
      azure.subscription_id) value="$cfg_subscription_id" ;;
      azure.tenant_id) value="$cfg_tenant_id" ;;
      ci.azure_client_id) value="$cfg_client_id" ;;
    esac
    if [[ -z "$value" ]]; then
      error "'$field' is not set or is empty in $rel."
      ok=false
    fi
  done
  if [[ "$ok" != true ]]; then
    error "Every deployment config needs env, deployment_id, azure.location, azure.subscription_id, azure.tenant_id and ci.azure_client_id. See deployments/configs/default.yaml."
    return 1
  fi

  # The file name is the workspace name, and main.tf loads
  # configs/<workspace>.yaml. So the name must match the fields inside.
  local expected="$cfg_env-$cfg_deployment_id"
  if [[ "$expected" != "$name" ]]; then
    error "$rel has <env>-<deployment_id> '$expected', but the file name is '$name.yaml'. Rename the file or fix the fields so they match."
    ok=false
  fi

  local tier known=false
  for tier in "${TIERS[@]}"; do
    [[ "$cfg_env" == "$tier" ]] && known=true
  done
  if [[ "$known" != true ]]; then
    error "$rel has env '$cfg_env'. It must be one of: ${TIERS[*]}."
    ok=false
  fi

  # A region short name is lowercase letters and digits, for example eastus.
  # A display name such as "East US" does not work.
  if [[ ! "$cfg_location" =~ ^[a-z0-9]+$ ]]; then
    error "$rel has azure.location '$cfg_location'. It must be a region short name in lowercase, for example eastus or westeurope. Run 'az account list-locations -o table' and use the Name column."
    ok=false
  fi

  for field in azure.subscription_id azure.tenant_id ci.azure_client_id; do
    case "$field" in
      azure.subscription_id) value="$cfg_subscription_id" ;;
      azure.tenant_id) value="$cfg_tenant_id" ;;
      ci.azure_client_id) value="$cfg_client_id" ;;
    esac
    if [[ ! "$value" =~ $GUID_REGEX ]]; then
      error "$rel has $field '$value'. It must be a GUID, for example 00000000-0000-0000-0000-000000000000."
      ok=false
    fi
  done

  # Quoted values are always strings, so only unquoted values are a problem.
  local style
  for field in env deployment_id; do
    case "$field" in
      env) value="$cfg_env" style="$cfg_env_style" ;;
      deployment_id) value="$cfg_deployment_id" style="$cfg_deployment_id_style" ;;
    esac
    if [[ "$style" != double && "$style" != single ]] && looks_like_number "$value"; then
      error "$rel has $field $value without quotes. YAML reads it as a number, so OpenTofu changes it (for example 1234e567 becomes a 571-digit number). Put the value in quotes: $field: \"$value\"."
      if [[ "$field" == deployment_id ]]; then
        echo "  For a new deployment, you can instead run 'task gen-deploy-id' for a new ID." >&2
      fi
      ok=false
    fi
  done

  if [[ ! -f "$BACKENDS_DIR/$name.azurerm.tfbackend" ]]; then
    error "Backend file deployments/backends/$name.azurerm.tfbackend does not exist. Copy deployments/backends/default.azurerm.tfbackend and fill it in."
    ok=false
  fi

  [[ "$ok" == true ]]
}

# Load the config for $DEPLOYMENT, check it, and export the values the
# OpenTofu steps and the azurerm provider and backend need.
load_deployment() {
  if [[ -z "${DEPLOYMENT:-}" ]]; then
    fail "DEPLOYMENT is not set. Set it to a config file name without '.yaml', for example develop-a1b2c3d4."
  fi
  if [[ ! "$DEPLOYMENT" =~ ^[A-Za-z0-9._-]+$ ]]; then
    fail "DEPLOYMENT '$DEPLOYMENT' has characters that are not allowed. Use letters, numbers, '.', '_' and '-'."
  fi
  if [[ "$DEPLOYMENT" == "default" ]]; then
    fail "deployments/configs/default.yaml only documents the config format. Set DEPLOYMENT to a real deployment."
  fi

  local file="$CONFIGS_DIR/$DEPLOYMENT.yaml"
  if [[ ! -f "$file" ]]; then
    error "Config file deployments/configs/$DEPLOYMENT.yaml does not exist."
    if [[ -f "$CONFIGS_DIR/$DEPLOYMENT.yml" ]]; then
      echo "Found deployments/configs/$DEPLOYMENT.yml. tf.sh reads only .yaml files. Rename it to $DEPLOYMENT.yaml." >&2
    fi
    local found=() f
    for f in "$CONFIGS_DIR"/*.yaml; do
      [[ -e "$f" ]] || continue
      f="$(basename "$f" .yaml)"
      [[ "$f" == "default" ]] || found+=("$f")
    done
    if ((${#found[@]} > 0)); then
      echo "Deployments found: ${found[*]}" >&2
    else
      echo "No deployment configs found. Copy deployments/configs/default.yaml to <env>-<deployment_id>.yaml." >&2
    fi
    exit 1
  fi

  read_config "$file" || exit 1
  validate_config "$DEPLOYMENT" "$file" || exit 1

  export ENV="$cfg_env"
  export DEPLOYMENT_ID="$cfg_deployment_id"
  export DEPLOYMENT_WORKSPACE="$DEPLOYMENT"
  # The azurerm provider and backend read these. The provider also gets the
  # same values from the config in providers.tf. The location goes to
  # terraform/ through main.tf, so it needs no variable here.
  export ARM_SUBSCRIPTION_ID="$cfg_subscription_id"
  export ARM_TENANT_ID="$cfg_tenant_id"

  echo "Deployment: $DEPLOYMENT (env=$ENV deployment_id=$DEPLOYMENT_ID location=$cfg_location subscription=$ARM_SUBSCRIPTION_ID)"
}

# ─────────────────────────────────────────────────────────────────────────────
# Azure auth
#
# Secrets (OIDC tokens and access tokens) never go on a command line, because
# other processes on the machine can read command lines (for example with
# ps). printf is a bash builtin, so it starts no process. It writes the
# secret to curl's stdin, and curl reads it with "-H @-" (a header) or
# "--data-urlencode name@-" (a form field). Secrets also never go to a file
# or to the log.

# Print the claims (the JSON payload) of a JWT read from stdin. Return
# non-zero if it is not a JWT.
jwt_claims() {
  # A JWT is header.payload.signature. The payload is base64url without
  # padding, so convert it to plain base64 and add the padding back.
  local payload
  payload="$(cut -d. -f2 | tr '_-' '/+')"
  [[ -n "$payload" ]] || return 1
  while [[ $((${#payload} % 4)) -ne 0 ]]; do payload="${payload}="; done
  printf '%s' "$payload" | base64 -d 2>/dev/null | jq -ce . 2>/dev/null
}

# Print the claims of the CI job's OIDC token, so you can compare them with
# the federated identity credential (issuer, subject and audience must match
# exactly, and the match is case-sensitive). Never prints the token itself.
#   $1: auth mode (gitlab or github)
#   $2: the OIDC token
print_oidc_claims() {
  local mode="$1" token="$2" filter
  case "$mode" in
    gitlab) filter='{iss, sub, aud, project_path, project_id, ref, ref_type, ref_protected, environment}' ;;
    github) filter='{iss, sub, aud, repository, repository_id, repository_owner_id, ref, event_name, environment, job_workflow_ref}' ;;
  esac
  echo "Compare these OIDC token claims with the federated identity credential (issuer = iss, subject = sub, audience = aud):" >&2
  local claims
  if claims="$(printf '%s' "$token" | jwt_claims)"; then
    jq "$filter" <<<"$claims" >&2
  else
    echo "  (claim decode failed)" >&2
  fi
}

# Print a hint for an AADSTS error code from Entra ID.
#   $1: error_description from Entra ID
aadsts_hint() {
  local code
  code="$(grep -Eo 'AADSTS[0-9]+' <<<"$1" | head -n 1 || true)"
  case "$code" in
    AADSTS700213)
      echo "  Hint: no federated identity credential matches the token. Most often the subject is wrong. The match is exact and case-sensitive, and the message above shows the subject that was sent. A wrong issuer or audience can also give this error." ;;
    AADSTS700211)
      echo "  Hint: no federated identity credential has this token's issuer. GitLab: the issuer is the GitLab URL, for example https://gitlab.com. GitHub: https://token.actions.githubusercontent.com." ;;
    AADSTS70021)
      echo "  Hint: no federated identity credential matches the token. If you created the credential only a few minutes ago, wait a few minutes and run the job again." ;;
    AADSTS70025)
      echo "  Hint: the identity ci.azure_client_id has no federated identity credentials. Add one for this pipeline." ;;
    AADSTS700016)
      echo "  Hint: Entra ID cannot find ci.azure_client_id ($cfg_client_id) in tenant $cfg_tenant_id. Check both IDs in the deployment config." ;;
    AADSTS700024)
      echo "  Hint: the OIDC token has expired. Run the job again." ;;
    AADSTS700223 | AADSTS700238)
      echo "  Hint: the tenant does not allow workload identity federation for this identity. Ask your Entra ID admin." ;;
    AADSTS90002)
      echo "  Hint: tenant $cfg_tenant_id does not exist. Check azure.tenant_id in the deployment config." ;;
  esac
}

# Print which platform runs this script: gitlab, github or local.
ci_platform() {
  if [[ -n "${GITLAB_CI:-}" ]]; then
    echo gitlab
  elif [[ -n "${GITHUB_ACTIONS:-}" ]]; then
    echo github
  else
    echo local
  fi
}

# Unset every variable that could make the azurerm provider or backend use
# another credential than the CI job's OIDC token. Both prefer a storage key,
# a SAS token, a client certificate or a client secret over OIDC. A group or
# instance CI/CD variable (or a runner setting) could otherwise run OpenTofu
# as some other identity. Warn when any of them was set.
#   $@: more variable names to unset
clear_other_azure_credentials() {
  local var dropped=()
  for var in \
    ARM_ACCESS_KEY ARM_SAS_TOKEN \
    ARM_CLIENT_SECRET ARM_CLIENT_SECRET_FILE_PATH \
    ARM_CLIENT_CERTIFICATE ARM_CLIENT_CERTIFICATE_PATH ARM_CLIENT_CERTIFICATE_PASSWORD \
    ARM_CLIENT_ID_FILE_PATH \
    ARM_ADO_PIPELINE_SERVICE_CONNECTION_ID ARM_OIDC_AZURE_SERVICE_CONNECTION_ID AZURESUBSCRIPTION_SERVICE_CONNECTION_ID \
    ARM_USE_MSI ARM_MSI_ENDPOINT ARM_USE_AKS_WORKLOAD_IDENTITY \
    ARM_OIDC_TOKEN_FILE_PATH AZURE_FEDERATED_TOKEN_FILE \
    ARM_ENVIRONMENT ARM_METADATA_HOST ARM_METADATA_HOSTNAME \
    "$@"; do
    if [[ -n "${!var:-}" ]]; then
      dropped+=("$var")
    fi
    unset "$var"
  done
  if ((${#dropped[@]} > 0)); then
    printf "${YELLOW}%s${RESET}\n" "WARNING: This job has ${dropped[*]} set, maybe by a group, organization or instance CI/CD variable. tf.sh unsets them and uses the job's OIDC token for ci.azure_client_id." >&2
  fi
  # The Azure CLI login is on by default. Turn it off, so OpenTofu cannot
  # quietly use a stray az login on the runner. This is safe because
  # providers.tf sets subscription_id.
  export ARM_USE_CLI=false
}

# Get Azure credentials ready for OpenTofu. The mode depends on the platform,
# not on which Azure variables happen to be set.
#
# - GitLab CI: GitLab makes a JWT (JSON Web Token) for each job in
#   GITLAB_OIDC_TOKEN. This exports it as ARM_OIDC_TOKEN. The azurerm
#   provider and backend trade it with Entra ID for tokens of the identity
#   ci.azure_client_id.
# - GitHub Actions: GitHub sets ACTIONS_ID_TOKEN_REQUEST_URL and
#   ACTIONS_ID_TOKEN_REQUEST_TOKEN when the job has "id-token: write". The
#   azurerm provider and backend read them and ask GitHub for a new OIDC
#   token each time they need a new Entra ID token. So long jobs work, and
#   no azure/login step is needed.
# - Your machine: your Azure CLI login (the azurerm default).
#
# The backend file has use_azuread_auth = true, so the backend uses the same
# Entra ID login for the state blob. No storage keys are used.
#
# Then check_identity makes sure the login works for the right identity.
setup_auth() {
  local mode
  mode="$(ci_platform)"
  case "$mode" in
    gitlab)
      if [[ -z "${GITLAB_OIDC_TOKEN:-}" ]]; then
        error "GITLAB_OIDC_TOKEN is empty, so there are no Azure credentials."
        echo "  id_tokens is declared under default: in .ci/templates/tf-templates.yml. Check whether your pipeline overrides default: and drops it." >&2
        exit 1
      fi
      # ARM_OIDC_REQUEST_* do no harm here (a direct token wins), but unset
      # them too, so the setup is the same on both platforms.
      clear_other_azure_credentials ARM_OIDC_REQUEST_URL ARM_OIDC_REQUEST_TOKEN
      export ARM_USE_OIDC=true
      export ARM_CLIENT_ID="$cfg_client_id"
      export ARM_OIDC_TOKEN="$GITLAB_OIDC_TOKEN"
      echo "Using the GitLab OIDC token for client ID $ARM_CLIENT_ID in tenant $ARM_TENANT_ID."
      ;;
    github)
      if [[ -z "${ACTIONS_ID_TOKEN_REQUEST_URL:-}" || -z "${ACTIONS_ID_TOKEN_REQUEST_TOKEN:-}" ]]; then
        error "GitHub gave this job no OIDC token, so there are no Azure credentials."
        echo "  The job needs 'permissions: id-token: write'. On pull requests from forks, GitHub gives no OIDC token, so only the validate and setup jobs run." >&2
        exit 1
      fi
      # A direct token (ARM_OIDC_TOKEN) wins over the GitHub request URL,
      # and ARM_OIDC_REQUEST_* win over ACTIONS_ID_TOKEN_REQUEST_*.
      clear_other_azure_credentials ARM_OIDC_TOKEN ARM_OIDC_REQUEST_URL ARM_OIDC_REQUEST_TOKEN
      export ARM_USE_OIDC=true
      export ARM_CLIENT_ID="$cfg_client_id"
      echo "Using GitHub OIDC tokens for client ID $ARM_CLIENT_ID in tenant $ARM_TENANT_ID."
      ;;
    local)
      echo "Not in CI. Using your Azure CLI login."
      # The provider and backend prefer these over the az login.
      local var
      for var in ARM_ACCESS_KEY ARM_SAS_TOKEN; do
        if [[ -n "${!var:-}" ]]; then
          echo "NOTE: $var is set. OpenTofu uses it for the state backend instead of your Azure CLI login." >&2
        fi
      done
      for var in ARM_CLIENT_SECRET ARM_CLIENT_SECRET_FILE_PATH ARM_CLIENT_CERTIFICATE ARM_CLIENT_CERTIFICATE_PATH ARM_CLIENT_CERTIFICATE_PASSWORD ARM_OIDC_TOKEN ARM_OIDC_TOKEN_FILE_PATH; do
        if [[ -n "${!var:-}" ]]; then
          echo "NOTE: $var is set. If ARM_CLIENT_ID is also set, OpenTofu uses it instead of your Azure CLI login." >&2
        fi
      done
      for var in ARM_USE_MSI ARM_USE_AKS_WORKLOAD_IDENTITY; do
        if [[ "${!var:-}" == true ]]; then
          echo "NOTE: $var is true. OpenTofu may use that identity instead of your Azure CLI login." >&2
        fi
      done
      if [[ "${ARM_USE_CLI:-}" == false ]]; then
        echo "NOTE: ARM_USE_CLI is false, so OpenTofu does not use your Azure CLI login." >&2
      fi
      ;;
  esac

  check_identity "$mode"
}

# Check that the Azure login works for the right identity.
#   $1: auth mode (gitlab, github or local)
check_identity() {
  local mode="$1"
  if [[ "$mode" == local ]]; then
    check_identity_local
  else
    check_identity_ci "$mode"
  fi
}

# In CI, do what OpenTofu will do, but with clear errors: trade the job's
# OIDC token for an Entra ID access token for ci.azure_client_id, check
# whose token it is, and read azure.subscription_id with it.
#   $1: auth mode (gitlab or github)
check_identity_ci() {
  local mode="$1" verbose=true
  [[ "${PRINT_OIDC_CLAIMS:-true}" == "true" ]] || verbose=false
  require_cmd curl "CI jobs need it to check the Azure login."
  require_cmd jq "CI jobs need it to check the Azure login."

  local oidc_token resp code body
  case "$mode" in
    gitlab) oidc_token="$GITLAB_OIDC_TOKEN" ;;
    github)
      # The response is JSON: {"value": "<token>"}.
      if ! resp="$(printf 'Authorization: bearer %s\n' "$ACTIONS_ID_TOKEN_REQUEST_TOKEN" |
        curl -sS --max-time 60 -H @- -w '\n%{http_code}' \
          "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=$OIDC_TOKEN_AUDIENCE")"; then
        fail "Could not reach GitHub to get an OIDC token. See the curl error above."
      fi
      code="${resp##*$'\n'}"
      body="${resp%$'\n'*}"
      oidc_token="$(jq -r '.value // empty' <<<"$body" 2>/dev/null || true)"
      if [[ "$code" != 200 || -z "$oidc_token" ]]; then
        fail "GitHub did not give an OIDC token (HTTP $code). Check that the job has 'permissions: id-token: write'."
      fi
      ;;
  esac

  # Client credentials grant with the OIDC token as the client assertion.
  if ! resp="$(printf '%s' "$oidc_token" |
    curl -sS --max-time 60 -w '\n%{http_code}' \
      --data-urlencode "grant_type=client_credentials" \
      --data-urlencode "client_id=$cfg_client_id" \
      --data-urlencode "scope=$ARM_URL/.default" \
      --data-urlencode "client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer" \
      --data-urlencode "client_assertion@-" \
      "$ENTRA_LOGIN_URL/$cfg_tenant_id/oauth2/v2.0/token")"; then
    fail "Could not reach Entra ID ($ENTRA_LOGIN_URL). See the curl error above."
  fi
  code="${resp##*$'\n'}"
  body="${resp%$'\n'*}"
  local access_token
  access_token="$(jq -r '.access_token // empty' <<<"$body" 2>/dev/null || true)"
  if [[ "$code" != 200 || -z "$access_token" ]]; then
    local err desc
    err="$(jq -r '.error // empty' <<<"$body" 2>/dev/null || true)"
    desc="$(jq -r '.error_description // empty' <<<"$body" 2>/dev/null || true)"
    error "Entra ID did not accept the $mode OIDC token for ci.azure_client_id $cfg_client_id in tenant $cfg_tenant_id (HTTP $code)."
    echo "  ${err:-unknown error}: ${desc:-no error description}" >&2
    aadsts_hint "$desc" >&2
    if [[ "$verbose" == true ]]; then
      print_oidc_claims "$mode" "$oidc_token"
    else
      echo "  Set PRINT_OIDC_CLAIMS to \"true\" to see the OIDC token claims." >&2
    fi
    exit 1
  fi

  # Check the tenant and client in the access token. Microsoft says to treat
  # its access tokens as opaque, so only warn when this one does not decode.
  local claims tid appid
  if claims="$(printf '%s' "$access_token" | jwt_claims)"; then
    tid="$(jq -r '.tid // empty' <<<"$claims")"
    # v1 tokens (ARM issues these) have appid. v2 tokens have azp.
    appid="$(jq -r '.appid // .azp // empty' <<<"$claims")"
    if [[ "${tid,,}" != "${cfg_tenant_id,,}" ]]; then
      fail "The Azure access token is for tenant '$tid', but azure.tenant_id is $cfg_tenant_id. tf.sh stops before OpenTofu touches the wrong tenant."
    fi
    if [[ "${appid,,}" != "${cfg_client_id,,}" ]]; then
      fail "The Azure access token is for client ID '$appid', but ci.azure_client_id is $cfg_client_id. CI must run as that identity."
    fi
  else
    printf "${YELLOW}%s${RESET}\n" "WARNING: Could not decode the Azure access token, so tf.sh cannot check its tenant and client ID. It goes on and checks the subscription." >&2
  fi

  if ! resp="$(printf 'Authorization: Bearer %s\n' "$access_token" |
    curl -sS --max-time 60 -H @- -w '\n%{http_code}' \
      "$ARM_URL/subscriptions/$cfg_subscription_id?api-version=2022-12-01")"; then
    fail "Could not reach Azure Resource Manager ($ARM_URL). See the curl error above."
  fi
  code="${resp##*$'\n'}"
  body="${resp%$'\n'*}"
  if [[ "$code" != 200 ]]; then
    local arm_err
    arm_err="$(jq -r '"\(.error.code // "unknown error"): \(.error.message // "no error message")"' <<<"$body" 2>/dev/null || echo "unknown error")"
    error "The identity ci.azure_client_id $cfg_client_id cannot read subscription $cfg_subscription_id (HTTP $code)."
    echo "  $arm_err" >&2
    echo "  Check azure.subscription_id, and give the identity a role on that subscription (for example Contributor). A new role assignment can take up to about 10 minutes to work." >&2
    exit 1
  fi
  local sub_name sub_state
  sub_name="$(jq -r '.displayName // ""' <<<"$body")"
  sub_state="$(jq -r '.state // ""' <<<"$body")"
  if [[ -n "$sub_state" && "$sub_state" != Enabled ]]; then
    printf "${YELLOW}%s${RESET}\n" "WARNING: Subscription $cfg_subscription_id is in state '$sub_state', not Enabled. Changes may fail." >&2
  fi
  echo "Azure identity check PASSED: client ID $cfg_client_id in tenant $cfg_tenant_id can read subscription '$sub_name' ($cfg_subscription_id)."
}

# On your own machine, check the Azure CLI login: it must see
# azure.subscription_id, and that subscription must be in azure.tenant_id.
# OpenTofu uses azure.subscription_id from the config even when your az
# default subscription is another one.
check_identity_local() {
  if [[ "${PRINT_OIDC_CLAIMS:-true}" != "true" ]]; then
    echo "NOTE: PRINT_OIDC_CLAIMS is false. Skipping the Azure identity check."
    return 0
  fi
  if ! command -v az >/dev/null 2>&1; then
    echo "NOTE: The 'az' CLI is not installed. Skipping the Azure identity check. Make sure your credentials are for tenant $cfg_tenant_id and can use subscription $cfg_subscription_id." >&2
    return 0
  fi
  if ! command -v jq >/dev/null 2>&1; then
    echo "NOTE: 'jq' is not installed. Skipping the Azure identity check." >&2
    return 0
  fi

  local current
  if ! current="$(az account show -o json)"; then
    fail "Your Azure CLI login does not work ('az account show' failed). Run 'az login --tenant $cfg_tenant_id'."
  fi
  local sub
  if ! sub="$(az account show --subscription "$cfg_subscription_id" -o json 2>/dev/null)"; then
    fail "Your Azure CLI login cannot see subscription $cfg_subscription_id (azure.subscription_id). Run 'az login --tenant $cfg_tenant_id', or check the ID in the deployment config."
  fi

  local sub_tenant sub_name user current_id
  sub_tenant="$(jq -r '.tenantId // ""' <<<"$sub")"
  sub_name="$(jq -r '.name // ""' <<<"$sub")"
  user="$(jq -r '"\(.user.name // "unknown") (\(.user.type // "unknown"))"' <<<"$sub")"
  current_id="$(jq -r '.id // ""' <<<"$current")"
  if [[ "${sub_tenant,,}" != "${cfg_tenant_id,,}" ]]; then
    fail "Subscription $cfg_subscription_id is in tenant '$sub_tenant', but azure.tenant_id is $cfg_tenant_id. Fix the deployment config."
  fi
  if [[ "${current_id,,}" != "${cfg_subscription_id,,}" ]]; then
    echo "NOTE: Your az default subscription is $current_id. OpenTofu uses $cfg_subscription_id from the config (ARM_SUBSCRIPTION_ID)." >&2
  fi
  echo "Azure identity check PASSED: $user can see subscription '$sub_name' ($cfg_subscription_id) in tenant $cfg_tenant_id."
  echo "NOTE: You run as yourself, not as the CI identity $cfg_client_id. CI may have different permissions." >&2
}

# ─────────────────────────────────────────────────────────────────────────────
# OpenTofu steps

# Init with this deployment's backend and select its workspace. Runs in
# deployments/.
#   $@: extra init flags
#
# The azurerm backend keeps the default workspace's state in the blob named
# by key (terraform.tfstate) and workspace <ws> in the blob "<key>env:<ws>",
# in the same container. A plain init reads the default workspace's blob,
# which this project never uses. So init goes straight to the deployment's
# workspace with TF_WORKSPACE, and reads only that workspace's blob.
#
# When the container has no workspaces yet, init with TF_WORKSPACE creates
# the workspace. When other workspaces exist, it fails for a missing one.
# Only then does this fall back to a plain init and
# `workspace select -or-create`. Both ways need the role Storage Blob Data
# Contributor on the state container. The simple setup is one container per
# deployment. See "State access" in README.md.
tf_init_workspace() {
  cd "$DEPLOYMENTS_DIR"
  local init_log
  init_log="$(mktemp)"
  echo "Running $TF_BIN init with $DEPLOYMENT.azurerm.tfbackend (workspace $DEPLOYMENT_WORKSPACE)"
  if TF_WORKSPACE="$DEPLOYMENT_WORKSPACE" "$TF_BIN" init -input=false -backend-config="backends/$DEPLOYMENT.azurerm.tfbackend" -reconfigure "$@" 2>&1 | tee "$init_log"; then
    rm -f -- "$init_log"
    echo "Selecting $TF_BIN workspace $DEPLOYMENT_WORKSPACE"
    "$TF_BIN" workspace select "$DEPLOYMENT_WORKSPACE"
    return
  fi
  if ! grep -q "workspace \"$DEPLOYMENT_WORKSPACE\" does not exist" "$init_log"; then
    rm -f -- "$init_log"
    fail "$TF_BIN init failed. See the output above."
  fi
  rm -f -- "$init_log"

  echo "Workspace $DEPLOYMENT_WORKSPACE does not exist yet. Creating it."
  if ! "$TF_BIN" init -input=false -backend-config="backends/$DEPLOYMENT.azurerm.tfbackend" -reconfigure "$@" \
    || ! "$TF_BIN" workspace select -or-create "$DEPLOYMENT_WORKSPACE"; then
    fail "Could not create workspace $DEPLOYMENT_WORKSPACE. The identity needs the role Storage Blob Data Contributor on the state container in deployments/backends/$DEPLOYMENT.azurerm.tfbackend. If it may not create blobs there, create the workspace once with wider rights (for example 'task switch' on your machine), then run this job again. See \"State access\" in README.md."
  fi
}

# Write a plan summary to the GitHub job page. Only runs on GitHub Actions.
#   $1: plan file name (in deployments/)
#   $2: heading
write_step_summary() {
  local plan_file="$1" heading="$2"
  [[ -n "${GITHUB_STEP_SUMMARY:-}" ]] || return 0

  local show_file result size
  show_file="$(mktemp)"
  if ! "$TF_BIN" show -no-color "$plan_file" >"$show_file" 2>&1; then
    echo "NOTE: $TF_BIN show failed; the step summary has no plan details." >&2
  fi
  result="$(grep -E '^(Plan: |No changes\.)' "$show_file" | head -n 1 || true)"
  # A plan that changes only outputs has no "Plan:" line.
  if [[ -z "$result" ]] && grep -q '^Changes to Outputs:' "$show_file"; then
    result="Output changes only"
  fi
  [[ -n "$result" ]] || result="No 'Plan:' line found. See the job log."
  size="$(wc -c <"$show_file")"

  {
    echo "### $heading"
    echo
    echo "**$result**"
    echo
    echo "<details><summary>$TF_BIN show output</summary>"
    echo
    echo "<pre>"
    # Escape HTML so the plan text shows as plain text inside <pre>.
    head -c "$SUMMARY_MAX_BYTES" "$show_file" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
    echo "</pre>"
    if ((size > SUMMARY_MAX_BYTES)); then
      echo
      echo "_Output cut at $SUMMARY_MAX_BYTES of $size bytes. See the job log or the plan artifact for the rest._"
    fi
    echo
    echo "</details>"
    echo
  } >>"$GITHUB_STEP_SUMMARY"
  rm -f "$show_file"
}

require_plan_file() {
  local plan_file="$1" plan_cmd="$2"
  if [[ ! -f "$DEPLOYMENTS_DIR/$plan_file" ]]; then
    fail "Plan file deployments/$plan_file does not exist. Run '$plan_cmd' for $DEPLOYMENT first, and pass its artifact to this job."
  fi
}

# A saved plan records the provider versions and hashes from the lock file.
# Apply fails when init picks other versions, so the plan step saves a copy
# of the lock file next to the plan, and the apply step puts it back before
# init.

# Copy deployments/.terraform.lock.hcl to deployments/$1. Run after init.
save_lock_file() {
  local saved="$1"
  if [[ ! -f "$DEPLOYMENTS_DIR/.terraform.lock.hcl" ]]; then
    fail "$TF_BIN init did not write deployments/.terraform.lock.hcl, so the apply step cannot use the same providers as this plan."
  fi
  cp "$DEPLOYMENTS_DIR/.terraform.lock.hcl" "$DEPLOYMENTS_DIR/$saved"
  echo "Saved the provider lock file as deployments/$saved"
}

# Copy deployments/$1 over deployments/.terraform.lock.hcl. Run before init.
#   $1: saved lock file name (in deployments/)
#   $2: the command that writes it
restore_lock_file() {
  local saved="$1" plan_cmd="$2"
  if [[ ! -f "$DEPLOYMENTS_DIR/$saved" ]]; then
    fail "Lock file deployments/$saved does not exist. Run '$plan_cmd' for $DEPLOYMENT first, and pass its artifact (with the .out and .lock.hcl files) to this job."
  fi
  cp "$DEPLOYMENTS_DIR/$saved" "$DEPLOYMENTS_DIR/.terraform.lock.hcl"
  echo "Using the provider lock file from the plan step (deployments/$saved)"
}

# Write deployments/$DEPLOYMENT.changes with "true" when the plan changes any
# resource or output, or "false" when it changes nothing. GitHub Actions uses
# it to skip the apply (and its approval) for a plan with no changes.
# A "read" (a data source read during apply) does not count as a change.
# An import or a moved block changes the state, so it counts.
#   $1: plan file name (in deployments/)
write_change_marker() {
  local plan_file="$1" marker="$DEPLOYMENT.changes" changes
  # cmd_plan has already checked that CI has jq.
  if ! command -v jq >/dev/null 2>&1; then
    echo "NOTE: 'jq' is not installed. Skipping deployments/$marker (only CI uses it)." >&2
    return 0
  fi
  changes="$("$TF_BIN" show -json "$plan_file" | jq -r '
    [ (.resource_changes // [])[]
      | select(
          (.change.actions != ["no-op"] and .change.actions != ["read"])
          or (.change.importing != null)
          or (.previous_address != null and .previous_address != .address)
        )
    ] + [ (.output_changes // {})[] | select(.actions != ["no-op"]) ]
    | length > 0
  ')"
  if [[ "$changes" != true && "$changes" != false ]]; then
    fail "Could not read the changes from $plan_file (jq printed '$changes')."
  fi
  printf '%s\n' "$changes" >"$DEPLOYMENTS_DIR/$marker"
  echo "Plan has changes: $changes (wrote deployments/$marker)"
}

cmd_validate() {
  require_tf
  cd "$REPO_ROOT"

  echo "Checking $TF_BIN formatting... If it fails, the pipeline job will fail"
  "$TF_BIN" fmt -recursive -check .
  echo "Formatting PASSED"

  cd "$DEPLOYMENTS_DIR"
  echo "Checking $TF_BIN validate..."
  "$TF_BIN" init -input=false -backend=false
  "$TF_BIN" validate
  echo "Validate PASSED"

  cd "$REPO_ROOT"
  if command -v shellcheck >/dev/null 2>&1; then
    echo "Checking CI scripts with shellcheck..."
    shellcheck .ci/scripts/*.sh
    echo "Shellcheck PASSED"
  else
    echo "NOTE: shellcheck is not installed; skipping the CI script check."
  fi
}

cmd_plan() {
  require_yq
  require_tf
  if [[ "$(ci_platform)" != local ]]; then
    require_cmd jq "The plan step needs it to write deployments/\$DEPLOYMENT.changes."
  fi
  load_deployment
  setup_auth
  tf_init_workspace
  save_lock_file "$DEPLOYMENT.lock.hcl"
  # Remove an old marker, so a failed plan cannot leave a stale one behind.
  rm -f "$DEPLOYMENTS_DIR/$DEPLOYMENT.changes"

  echo "Running $TF_BIN plan for $DEPLOYMENT_WORKSPACE workspace"
  "$TF_BIN" plan -input=false -out="$DEPLOYMENT.out"
  write_change_marker "$DEPLOYMENT.out"
  write_step_summary "$DEPLOYMENT.out" "Plan: $DEPLOYMENT"
  echo "Plan successful for $DEPLOYMENT_WORKSPACE workspace"
}

cmd_apply() {
  require_yq
  require_tf
  load_deployment
  require_plan_file "$DEPLOYMENT.out" "tf.sh plan"
  restore_lock_file "$DEPLOYMENT.lock.hcl" "tf.sh plan"
  setup_auth
  # readonly: fail instead of changing the lock file the plan was made with.
  tf_init_workspace -lockfile=readonly

  echo "Running $TF_BIN apply for $DEPLOYMENT_WORKSPACE workspace"
  "$TF_BIN" apply -input=false "$DEPLOYMENT.out"
  echo "Apply successful for $DEPLOYMENT_WORKSPACE workspace"
}

cmd_destroy_plan() {
  require_yq
  require_tf
  load_deployment
  setup_auth
  tf_init_workspace
  save_lock_file "$DEPLOYMENT-destroy.lock.hcl"

  echo "Running $TF_BIN plan -destroy for $DEPLOYMENT_WORKSPACE workspace"
  "$TF_BIN" plan -destroy -input=false -out="$DEPLOYMENT-destroy.out"
  write_step_summary "$DEPLOYMENT-destroy.out" "Destroy plan: $DEPLOYMENT"
  echo "Destroy-plan successful for $DEPLOYMENT_WORKSPACE workspace"
  printf "${YELLOW}%s${RESET}\n" "If you run the next pipeline job, it will destroy the $DEPLOYMENT environment. BE ABSOLUTELY SURE YOU WANT TO DO THIS!"
}

cmd_destroy() {
  require_yq
  require_tf
  load_deployment
  require_plan_file "$DEPLOYMENT-destroy.out" "tf.sh destroy-plan"
  restore_lock_file "$DEPLOYMENT-destroy.lock.hcl" "tf.sh destroy-plan"
  setup_auth
  # readonly: fail instead of changing the lock file the plan was made with.
  tf_init_workspace -lockfile=readonly

  echo "Running $TF_BIN destroy for $DEPLOYMENT_WORKSPACE workspace"
  "$TF_BIN" apply -auto-approve -input=false "$DEPLOYMENT-destroy.out"
  echo "Destroy successful for $DEPLOYMENT_WORKSPACE workspace"
}

# Print one line per tier in GITHUB_OUTPUT format, for example:
#   develop=[{"deployment":"develop-a1b2c3d4"}]
#   stage=[]
# GitHub Actions uses each line as the matrix for that tier's jobs. Each
# entry has only the deployment name. tf.sh reads the rest from the config
# in every job. Every config is checked first. If any config is bad,
# nothing goes to stdout.
# When ONLY_DEPLOYMENT is set, only that config is read and checked, and it
# is the only entry in the output.
cmd_matrix() {
  require_yq

  local -A tier_json=()
  local tier
  for tier in "${TIERS[@]}"; do tier_json[$tier]=""; done

  # Only <name>.yaml files are deployments. Stop on anything else, so a
  # config saved as .yml does not drop out of the pipeline without a word.
  local file base bad=0
  for file in "$CONFIGS_DIR"/*; do
    [[ -f "$file" ]] || continue
    base="$(basename "$file")"
    [[ "$base" == *.yaml ]] && continue
    if [[ "$base" == *.yml ]]; then
      error "deployments/configs/$base ends in .yml. tf.sh reads only .yaml files. Rename it to ${base%.yml}.yaml."
    else
      error "deployments/configs/$base is not a .yaml file. Only deployment configs (<env>-<deployment_id>.yaml) belong in deployments/configs/. Move or rename it."
    fi
    bad=$((bad + 1))
  done

  local only="${ONLY_DEPLOYMENT:-}"
  if [[ -n "$only" ]]; then
    if [[ ! "$only" =~ ^[A-Za-z0-9._-]+$ || "$only" == "default" ]]; then
      fail "ONLY_DEPLOYMENT '$only' is not a deployment name. Use a config file name without '.yaml', for example develop-a1b2c3d4."
    fi
    if [[ ! -f "$CONFIGS_DIR/$only.yaml" ]]; then
      if [[ -f "$CONFIGS_DIR/$only.yml" ]]; then
        fail "ONLY_DEPLOYMENT is '$only', but its config is deployments/configs/$only.yml. Rename it to $only.yaml."
      fi
      fail "ONLY_DEPLOYMENT is '$only', but deployments/configs/$only.yaml does not exist."
    fi
  fi

  local name obj
  for file in "$CONFIGS_DIR"/*.yaml; do
    [[ -e "$file" ]] || continue
    name="$(basename "$file" .yaml)"
    # default.yaml only documents the format.
    [[ "$name" == "default" ]] && continue
    [[ -z "$only" || "$name" == "$only" ]] || continue

    if ! read_config "$file" || ! validate_config "$name" "$file"; then
      bad=$((bad + 1))
      continue
    fi

    # yq builds the JSON so that quotes and other special characters are
    # escaped correctly.
    obj="$(NAME="$name" yq -n -o=json -I=0 '{"deployment": strenv(NAME)}')"
    if [[ -n "${tier_json[$cfg_env]}" ]]; then
      tier_json[$cfg_env]+=",$obj"
    else
      tier_json[$cfg_env]="$obj"
    fi
  done

  if ((bad > 0)); then
    fail "$bad problem(s) in deployments/configs/. Fix the errors above."
  fi

  for tier in "${TIERS[@]}"; do
    echo "$tier=[${tier_json[$tier]}]"
  done
}

main() {
  if (($# != 1)); then
    usage
    exit 2
  fi
  case "$1" in
    validate) cmd_validate ;;
    plan) cmd_plan ;;
    apply) cmd_apply ;;
    destroy-plan) cmd_destroy_plan ;;
    destroy) cmd_destroy ;;
    matrix) cmd_matrix ;;
    -h | --help | help) usage ;;
    *)
      usage
      exit 2
      ;;
  esac
}

main "$@"
