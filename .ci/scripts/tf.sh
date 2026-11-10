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
#   PRINT_OIDC_CLAIMS            "true" (default) prints the GitLab JWT claims
#                                when auth fails. In CI, the AWS identity
#                                check always runs. On your own machine,
#                                "false" skips the identity check.
#   GITLAB_CI                    Set by GitLab. Turns on GitLab auth mode.
#   GITLAB_OIDC_TOKEN            JWT that GitLab makes for the job (GitLab only).
#   AWS_WEB_IDENTITY_TOKEN_FILE  Optional, GitLab only. Where to write that JWT.
#                                The default is a file for this job only,
#                                "${TMPDIR:-/tmp}/gitlab-oidc-<job id>.jwt".
#                                tf.sh deletes the file when it exits.
#   GITHUB_ACTIONS               Set by GitHub. Turns on GitHub auth mode.
#   GITHUB_STEP_SUMMARY          Set by GitHub Actions. When set, plan and
#                                destroy-plan write a summary to it.
#
# Auth mode:
#   GitLab CI       tf.sh trades the job JWT for the ci.aws_role_arn role. It
#                   ignores (unsets) any static AWS keys and AWS_PROFILE.
#   GitHub Actions  aws-actions/configure-aws-credentials must run first.
#   Your machine    The normal AWS credential chain (AWS_PROFILE, SSO, ...).
# After auth, tf.sh checks with `aws sts get-caller-identity` that it runs as
# the ci.aws_role_arn role (in CI) or in that role's account (on your
# machine). In CI the aws CLI must be installed.
#
# A deployment is one file in deployments/configs/. The file name, the
# workspace name and DEPLOYMENT are the same value:
# <env>-<deployment_id>. This script reads env, deployment_id, aws.region
# and ci.aws_role_arn from that file with yq (mikefarah yq 4.18 or newer). The plan step also needs jq in CI.

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
  if ! fields="$(yq '.env // "", .deployment_id // "", .aws.region // "", .ci.aws_role_arn // "", (.env | style), (.deployment_id | style)' "$file")"; then
    # yq prints its own error above this line.
    error "yq could not read ${file#"$REPO_ROOT"/}. See the yq error above."
    return 1
  fi
  local -a values
  mapfile -t values <<<"$fields"
  cfg_env="${values[0]:-}"
  cfg_deployment_id="${values[1]:-}"
  cfg_region="${values[2]:-}"
  cfg_role_arn="${values[3]:-}"
  cfg_env_style="${values[4]:-}"
  cfg_deployment_id_style="${values[5]:-}"
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
  for field in env deployment_id aws.region ci.aws_role_arn; do
    case "$field" in
      env) value="$cfg_env" ;;
      deployment_id) value="$cfg_deployment_id" ;;
      aws.region) value="$cfg_region" ;;
      ci.aws_role_arn) value="$cfg_role_arn" ;;
    esac
    if [[ -z "$value" ]]; then
      error "'$field' is not set or is empty in $rel."
      ok=false
    fi
  done
  if [[ "$ok" != true ]]; then
    error "Every deployment config needs env, deployment_id, aws.region and ci.aws_role_arn. See deployments/configs/default.yaml."
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

  if [[ ! "$cfg_role_arn" =~ ^arn:aws[a-z-]*:iam::[0-9]{12}:role/.+ ]]; then
    error "$rel has ci.aws_role_arn '$cfg_role_arn'. It must be an IAM role ARN, for example arn:aws:iam::123456789012:role/ci-my-repo-deploy."
    ok=false
  fi

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

  if [[ ! -f "$BACKENDS_DIR/$name.s3.tfbackend" ]]; then
    error "Backend file deployments/backends/$name.s3.tfbackend does not exist. Copy deployments/backends/default.s3.tfbackend and fill it in."
    ok=false
  fi

  [[ "$ok" == true ]]
}

# Load the config for $DEPLOYMENT, check it, and export the values the
# OpenTofu steps and the AWS SDK need.
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
  export AWS_REGION="$cfg_region"
  export AWS_DEFAULT_REGION="$cfg_region"

  echo "Deployment: $DEPLOYMENT (env=$ENV deployment_id=$DEPLOYMENT_ID region=$AWS_REGION)"
}

# ─────────────────────────────────────────────────────────────────────────────
# AWS auth

# Print the claims inside the GitLab JWT, so you can compare them with the
# role trust policy conditions.
print_gitlab_claims() {
  echo "Compare the JWT claims below against the role trust policy conditions:" >&2
  if command -v jq >/dev/null 2>&1; then
    # A JWT is header.payload.signature. The payload is base64url without
    # padding, so convert it to plain base64 and add the padding back.
    local payload
    payload="$(printf '%s' "$GITLAB_OIDC_TOKEN" | cut -d. -f2 | tr '_-' '/+')"
    while [[ $((${#payload} % 4)) -ne 0 ]]; do payload="${payload}="; done
    printf '%s' "$payload" | base64 -d 2>/dev/null | jq '{sub, aud, ref, ref_type, project_path, environment}' >&2 || echo "  (claim decode failed)" >&2
  else
    echo "  (install jq in this image to see decoded claims)" >&2
  fi
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

# Get AWS credentials ready for OpenTofu. The mode depends on the platform,
# not on which AWS variables happen to be set.
#
# - GitLab CI: GitLab makes a JWT (JSON Web Token) for each job in
#   GITLAB_OIDC_TOKEN. This writes it to AWS_WEB_IDENTITY_TOKEN_FILE and
#   exports AWS_ROLE_ARN. The AWS SDK then trades the token for role
#   credentials. Static keys and AWS_PROFILE are unset first, because the SDK
#   prefers them over the token. A group or instance CI/CD variable could
#   otherwise run OpenTofu as some other identity.
# - GitHub Actions: aws-actions/configure-aws-credentials runs before this
#   script and sets AWS_ACCESS_KEY_ID.
# - Your machine: the normal AWS credential chain (AWS_PROFILE, SSO, ...).
#
# Then check_identity makes sure the credentials belong to the right role.
setup_auth() {
  local mode
  mode="$(ci_platform)"
  case "$mode" in
    gitlab)
      if [[ -z "${GITLAB_OIDC_TOKEN:-}" ]]; then
        error "GITLAB_OIDC_TOKEN is empty, so there are no AWS credentials."
        echo "  id_tokens is declared under default: in .ci/templates/tf-templates.yml. Check whether your pipeline overrides default: and drops it." >&2
        exit 1
      fi
      local var dropped=()
      for var in AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_PROFILE; do
        if [[ -n "${!var:-}" ]]; then
          dropped+=("$var")
        fi
        unset "$var"
      done
      if ((${#dropped[@]} > 0)); then
        printf "${YELLOW}%s${RESET}\n" "WARNING: This job has ${dropped[*]} set, maybe by a group or instance CI/CD variable. tf.sh unsets them and uses the GitLab OIDC token for ci.aws_role_arn." >&2
      fi

      export AWS_WEB_IDENTITY_TOKEN_FILE="${AWS_WEB_IDENTITY_TOKEN_FILE:-${TMPDIR:-/tmp}/gitlab-oidc-${CI_JOB_ID:-$$}.jwt}"
      export AWS_ROLE_ARN="$cfg_role_arn"
      # The SDK reads the file again when it renews credentials, so delete
      # it only when tf.sh exits, after OpenTofu is done.
      trap 'rm -f -- "$AWS_WEB_IDENTITY_TOKEN_FILE"' EXIT
      (
        umask 077
        printf '%s\n' "$GITLAB_OIDC_TOKEN" >"$AWS_WEB_IDENTITY_TOKEN_FILE"
      )
      chmod 600 "$AWS_WEB_IDENTITY_TOKEN_FILE"
      echo "Wrote the GitLab OIDC token to $AWS_WEB_IDENTITY_TOKEN_FILE. Role: $AWS_ROLE_ARN"
      ;;
    github)
      if [[ -z "${AWS_ACCESS_KEY_ID:-}" ]]; then
        error "No AWS credentials found."
        echo "  Run aws-actions/configure-aws-credentials before this step. On pull requests from forks, GitHub gives no OIDC token, so only the validate and setup jobs run." >&2
        exit 1
      fi
      echo "Using the AWS credentials from aws-actions/configure-aws-credentials."
      ;;
    local)
      echo "Not in CI. Using your AWS credential chain (AWS_PROFILE=${AWS_PROFILE:-<not set>})."
      ;;
  esac

  check_identity "$mode"
}

# Check that the AWS credentials belong to ci.aws_role_arn.
#   $1: auth mode (gitlab, github or local)
# In CI the caller must be arn:<partition>:sts::<account>:assumed-role/<role
# name>/<session>, with the account and role name of ci.aws_role_arn. On your
# own machine only the account must match, because you may use another role
# or an SSO session.
check_identity() {
  local mode="$1" verbose=true
  [[ "${PRINT_OIDC_CLAIMS:-true}" == "true" ]] || verbose=false

  if [[ "$mode" == local && "$verbose" != true ]]; then
    echo "NOTE: PRINT_OIDC_CLAIMS is false. Skipping the AWS identity check."
    return 0
  fi
  if ! command -v aws >/dev/null 2>&1; then
    if [[ "$mode" == local ]]; then
      echo "NOTE: The 'aws' CLI is not installed. Skipping the AWS identity check. Make sure your credentials are for account $(cut -d: -f5 <<<"$cfg_role_arn")." >&2
      return 0
    fi
    fail "The 'aws' CLI is not installed or not on PATH. CI jobs need it to check that they run as ci.aws_role_arn ($cfg_role_arn)."
  fi

  local caller
  if ! caller="$(AWS_PAGER="" aws sts get-caller-identity --query Arn --output text)"; then
    case "$mode" in
      gitlab)
        error "AssumeRoleWithWebIdentity failed for $cfg_role_arn."
        if [[ "$verbose" == true ]]; then
          print_gitlab_claims
        else
          echo "  Set PRINT_OIDC_CLAIMS to \"true\" to see the JWT claims." >&2
        fi
        ;;
      github)
        error "The AWS credentials in this job do not work (sts get-caller-identity failed). Check the role trust policy and the configure-aws-credentials step."
        ;;
      local)
        error "Your AWS credentials do not work (sts get-caller-identity failed). Set AWS_PROFILE, or run 'aws sso login'."
        ;;
    esac
    exit 1
  fi
  local want_partition want_account want_role
  want_partition="$(cut -d: -f2 <<<"$cfg_role_arn")"
  want_account="$(cut -d: -f5 <<<"$cfg_role_arn")"
  # A role ARN can have a path (role/team/ci). The role name is the last part.
  want_role="${cfg_role_arn##*/}"

  local caller_partition caller_account caller_kind caller_role=""
  caller_partition="$(cut -d: -f2 <<<"$caller")"
  caller_account="$(cut -d: -f5 <<<"$caller")"
  caller_kind="$(cut -d: -f6 <<<"$caller" | cut -d/ -f1)"
  if [[ "$caller" =~ ^arn:[a-z-]+:sts::[0-9]{12}:assumed-role/([^/]+)/ ]]; then
    caller_role="${BASH_REMATCH[1]}"
  fi

  if [[ "$caller_partition" != "$want_partition" || "$caller_account" != "$want_account" ]]; then
    fail "AWS credentials are for '$caller', but ci.aws_role_arn is $cfg_role_arn. The account or partition does not match, so tf.sh stops before OpenTofu touches the wrong account."
  fi
  if [[ "$caller_kind" == assumed-role && "$caller_role" == "$want_role" ]]; then
    echo "AWS identity check PASSED: $caller"
    return 0
  fi
  if [[ "$mode" == local ]]; then
    printf "${YELLOW}%s${RESET}\n" "WARNING: You run as '$caller', not as the CI role $cfg_role_arn. The account matches, so tf.sh goes on. CI may have different permissions." >&2
    return 0
  fi
  fail "AWS credentials are for '$caller', but ci.aws_role_arn is $cfg_role_arn. CI must run as that role. Check the role ARN in the deployment config and in the CI setup."
}

# ─────────────────────────────────────────────────────────────────────────────
# OpenTofu steps

# Init with this deployment's backend and select its workspace. Runs in
# deployments/.
#   $@: extra init flags
#
# A plain init reads the state of the default workspace. With
# workspace_key_prefix, that state is at the bucket root, outside the
# deployment's prefix. A CI role that may read only its own prefix gets
# 403 Forbidden there. So init goes straight to the deployment's workspace
# with TF_WORKSPACE, and reads only that workspace's state.
#
# When the prefix has no workspaces yet, init with TF_WORKSPACE creates the
# workspace. When other workspaces exist, it fails for a missing one. Only
# then does this fall back to a plain init and `workspace select -or-create`.
# That fallback needs read access to the bucket root. See "State access" in
# README.md.
tf_init_workspace() {
  cd "$DEPLOYMENTS_DIR"
  local init_log
  init_log="$(mktemp)"
  echo "Running $TF_BIN init with $DEPLOYMENT.s3.tfbackend (workspace $DEPLOYMENT_WORKSPACE)"
  if TF_WORKSPACE="$DEPLOYMENT_WORKSPACE" "$TF_BIN" init -input=false -backend-config="backends/$DEPLOYMENT.s3.tfbackend" -reconfigure "$@" 2>&1 | tee "$init_log"; then
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
  if ! "$TF_BIN" init -input=false -backend-config="backends/$DEPLOYMENT.s3.tfbackend" -reconfigure "$@" \
    || ! "$TF_BIN" workspace select -or-create "$DEPLOYMENT_WORKSPACE"; then
    fail "Could not create workspace $DEPLOYMENT_WORKSPACE. If the CI role may use only its own prefix of the state bucket, it cannot create a workspace. Create it once with wider credentials (for example 'task switch' on your machine), then run this job again. See \"State access\" in README.md."
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
#   develop=[{"deployment":"develop-a1b2c3d4","region":"us-east-1","role_arn":"arn:aws:iam::123456789012:role/ci-my-repo-deploy"}]
#   stage=[]
# GitHub Actions uses each line as the matrix for that tier's jobs. Every
# config is checked first. If any config is bad, nothing goes to stdout.
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
    # escaped correctly. validate_config has checked that region and role_arn
    # are set and that role_arn is an ARN, so both are plain strings.
    obj="$(NAME="$name" yq -o=json -I=0 '{"deployment": strenv(NAME), "region": .aws.region, "role_arn": .ci.aws_role_arn}' "$file")"
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
