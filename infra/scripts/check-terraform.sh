#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/../.." && pwd)
TERRAFORM_DIR="$REPO_ROOT/infra/terraform"
OAUTH_CLIENTS_FILE="$REPO_ROOT/infra/oauth-clients.json"
OAUTH_RENDERER="$TERRAFORM_DIR/modules/docker/oauth-clients/scripts/render-sql.py"
REQUIRED_SHELLCHECK_VERSION="0.11.0"

check_tracked_sensitive_artifacts() {
  local repository_root="$1"
  local tracked_path basename tracked_list
  local sensitive_paths=()

  if ! git -C "$repository_root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    printf 'Cannot inspect tracked Terraform artifacts outside a Git worktree: %s\n' \
      "$repository_root" >&2
    return 2
  fi

  tracked_list=$(mktemp "${TMPDIR:-/tmp}/apollo-tracked-files.XXXXXX")
  if ! git -C "$repository_root" ls-files -z >"$tracked_list"; then
    rm -f -- "$tracked_list"
    echo "Could not inspect the Git index for sensitive Terraform artifacts." >&2
    return 2
  fi

  while IFS= read -r -d '' tracked_path; do
    basename=${tracked_path##*/}
    case "$basename" in
      .terraform.lock.hcl|*.example)
        continue
        ;;
      *.tfstate|*.tfstate.*|*.tfvars|*.tfvars.*|\
      crash.log|crash.log.*|crash.*.log|crash.*.log.*|\
      backend*.hcl|backend*.hcl.*|*.backend.hcl|*.backend.hcl.*|\
      *.tfbackend|*.tfbackend.*|\
      tfplan|tfplan.*|*.tfplan|*.tfplan.*)
        sensitive_paths+=("$tracked_path")
        ;;
    esac
  done <"$tracked_list"
  rm -f -- "$tracked_list"

  if ((${#sensitive_paths[@]} == 0)); then
    return 0
  fi

  echo "Tracked sensitive Terraform artifacts are forbidden:" >&2
  for tracked_path in "${sensitive_paths[@]}"; do
    printf '  %s\n' "$tracked_path" >&2
  done
  echo "Remove these paths from the Git index and rotate any exposed credentials." >&2
  return 1
}

if [ "${BASH_SOURCE[0]}" != "$0" ]; then
  return 0
fi

required_tools=(terraform tflint shellcheck jq python3 git)
missing_tools=()

for tool in "${required_tools[@]}"; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    missing_tools+=("$tool")
  fi
done

if ((${#missing_tools[@]} > 0)); then
  printf 'Missing required tool(s): %s\n' "${missing_tools[*]}" >&2
  printf 'Install every required tool and rerun %s.\n' "$0" >&2
  exit 127
fi

shellcheck_version=$(shellcheck --version | awk '$1 == "version:" { print $2; exit }')
if [ "$shellcheck_version" != "$REQUIRED_SHELLCHECK_VERSION" ]; then
  printf 'ShellCheck %s is required; found %s. Use the digest-pinned CI image or install the exact release.\n' \
    "$REQUIRED_SHELLCHECK_VERSION" "${shellcheck_version:-unknown}" >&2
  exit 2
fi

export CHECKPOINT_DISABLE=1
export TF_IN_AUTOMATION=true

section() {
  printf '\n==> %s\n' "$1"
}

section "Rejecting tracked sensitive Terraform artifacts"
check_tracked_sensitive_artifacts "$REPO_ROOT"

section "Checking Terraform formatting"
terraform fmt -check -recursive -diff "$TERRAFORM_DIR"

active_roots=(bootstrap local vps)
validation_data_dir=$(mktemp -d "${TMPDIR:-/tmp}/apollo-terraform-validation.XXXXXX")
cleanup() {
  rm -rf -- "$validation_data_dir"
}
trap cleanup EXIT
tflint_directories="$validation_data_dir/tflint-directories"

if ! find "$TERRAFORM_DIR" -type f -name '*.tf' \
  -not -path '*/.terraform/*' \
  -not -path '*/.setup-backups/*' \
  -print \
  | sed 's#/[^/]*$##' \
  | LC_ALL=C sort -u >"$tflint_directories"; then
  echo "Could not discover Terraform source directories for TFLint." >&2
  exit 1
fi

if [ ! -s "$tflint_directories" ]; then
  echo "No Terraform source directories were discovered for TFLint." >&2
  exit 1
fi

section "Initializing TFLint"
(
  cd "$TERRAFORM_DIR"
  tflint --init --config="$TERRAFORM_DIR/.tflint.hcl"
)

tflint_count=0
while IFS= read -r terraform_dir; do
  relative_dir=${terraform_dir#"$TERRAFORM_DIR"}
  relative_dir=${relative_dir#/}
  [ -n "$relative_dir" ] || relative_dir=.

  section "Running TFLint for $relative_dir"
  (
    cd "$terraform_dir"
    tflint \
      --config="$TERRAFORM_DIR/.tflint.hcl" \
      --format=compact \
      --minimum-failure-severity=warning
  )
  tflint_count=$((tflint_count + 1))
done <"$tflint_directories"
printf 'Linted %d Terraform source directories at warning-or-higher.\n' "$tflint_count"

for environment in "${active_roots[@]}"; do
  root="$TERRAFORM_DIR/$environment"
  data_dir="$validation_data_dir/$environment"
  mkdir -p "$data_dir"

  section "Initializing and validating the $environment Terraform root"
  TF_DATA_DIR="$data_dir" terraform -chdir="$root" init \
    -backend=false \
    -input=false \
    -lockfile=readonly \
    -no-color
  TF_DATA_DIR="$data_dir" terraform -chdir="$root" validate -no-color
done

modules_copy="$validation_data_dir/modules"
cp -R "$TERRAFORM_DIR/modules" "$modules_copy"

while IFS= read -r root; do
  module=${root#"$modules_copy"/}
  data_dir="$validation_data_dir/module-${module//\//-}"
  mkdir -p "$data_dir"

  section "Initializing and validating the $module Terraform module"
  TF_DATA_DIR="$data_dir" terraform -chdir="$root" init \
    -backend=false \
    -input=false \
    -no-color
  TF_DATA_DIR="$data_dir" terraform -chdir="$root" validate -no-color
done < <(
  find "$modules_copy" -type f -name '*.tf' -not -path '*/.terraform/*' -print \
    | sed 's#/[^/]*$##' \
    | LC_ALL=C sort -u
)

section "Running ShellCheck"
shellcheck_failed=0
while IFS= read -r shell_file; do
  if ! shellcheck "$shell_file"; then
    shellcheck_failed=1
  fi
done < <(find "$REPO_ROOT/infra" -type f -name '*.sh' -print | LC_ALL=C sort)

if ((shellcheck_failed != 0)); then
  exit 1
fi

section "Running infrastructure shell regression tests"
# The hosted wizard deliberately rejects every inherited TF_* setting. The
# checker uses this one only for the Terraform commands above, so do not leak it
# into production-context regression tests.
unset TF_IN_AUTOMATION
while IFS= read -r test_file; do
  bash "$test_file"
done < <(find "$REPO_ROOT/infra/scripts/tests" -maxdepth 1 -type f -name '*-test.sh' -print | LC_ALL=C sort)

section "Checking that database secrets are not placed in process arguments"
if grep -REn --exclude='check-terraform.sh' -- \
  'docker exec.*(-e|--env)[[:space:]]+PGPASSWORD|ssh.*(DB_PASS|PASSWORD)[A-Za-z0-9_]*=|curl.*Authorization:[[:space:]]*Bearer' \
  "$REPO_ROOT/infra/scripts" "$REPO_ROOT/infra/setup.sh"; then
  echo "Infrastructure secrets must be streamed to protected stdin payloads, not process arguments." >&2
  exit 1
fi

if grep -REin --exclude='check-terraform.sh' -- \
  '(^|[[:space:]])(-v|--set)(=|[[:space:]]+)[^[:space:]]*(pass(word)?|passwd|secret|token)[^[:space:]]*=' \
  "$REPO_ROOT/infra/scripts" \
  || grep -REn \
    --exclude-dir='.terraform' \
    --exclude='*.tfstate*' \
    --exclude='tfplan*' \
    --exclude='*.tfplan*' \
    -- '--require[p]ass' "$TERRAFORM_DIR"; then
  echo "Password-like psql variables and Redis passwords must not be placed in process arguments." >&2
  exit 1
fi

section "Validating OAuth client JSON"
jq --exit-status '
  type == "array" and length > 0 and
  all(.[]; (.key | type == "string" and length > 0) and
           (.name | type == "string" and length > 0) and
           (.grantTypes | type == "array" and length > 0) and
           (.scope | type == "string" and length > 0) and
           (has("redirectUris") | not) and
           (has("postLogoutRedirectUris") | not)) and
  ([.[].key] | sort == ["billing", "platform", "signal"])
' "$OAUTH_CLIENTS_FILE" >/dev/null

section "Checking OAuth SQL renderer"
PYTHONPYCACHEPREFIX="$validation_data_dir/pycache" python3 -m py_compile "$OAUTH_RENDERER"
renderer_output=$(
  printf '%s' '{"smoke":{"record_id":"00000000-0000-4000-8000-000000000001","key":"smoke","name":"Smoke Test","client_id":"AbcdefghijklmnopqrstuvwxyzABCDEF","client_secret":"renderer-smoke-secret-0123456789","is_public":false,"grant_types":["client_credentials"],"redirect_uris":[],"post_logout_redirect_uris":[],"scope":"openid","skip_consent":true}}' \
    | python3 "$OAUTH_RENDERER"
)
grep -q '^BEGIN;$' <<<"$renderer_output"
grep -q '^COMMIT;$' <<<"$renderer_output"
if grep -q 'renderer-smoke-secret' <<<"$renderer_output"; then
  echo "OAuth renderer leaked a plaintext client secret." >&2
  exit 1
fi

section "All infrastructure checks passed"
