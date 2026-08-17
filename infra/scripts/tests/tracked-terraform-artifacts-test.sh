#!/usr/bin/env bash

# This test sources the tracked-artifact predicate without running the complete
# Terraform quality gate.
# shellcheck disable=SC1091,SC2034

set -euo pipefail

test_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$test_dir/../../.." && pwd)
check_script="$repo_root/infra/scripts/check-terraform.sh"
test_root=$(mktemp -d "${TMPDIR:-/tmp}/apollo-tracked-artifacts.XXXXXX")
fixture_repo="$test_root/repository"

cleanup() {
  rm -rf -- "$test_root"
}
trap cleanup EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

# shellcheck source=../check-terraform.sh
source "$check_script"

git init --quiet "$fixture_repo"

stage_fixture() {
  local path="$1"

  mkdir -p -- "$fixture_repo/$(dirname -- "$path")"
  : >"$fixture_repo/$path"
  git -C "$fixture_repo" add --force -- "$path"
}

allowed_paths=(
  infra/terraform/local/.terraform.lock.hcl
  infra/terraform/vps/backend.hcl.example
  infra/terraform/vps/production.tfbackend.example
  infra/terraform/vps/terraform.tfvars.example
  infra/terraform/vps/production.auto.tfvars.example
  infra/terraform/vps/terraform.tfstate.example
  infra/terraform/vps/tfplan.example
  infra/terraform/vps/main.tf
)

for allowed_path in "${allowed_paths[@]}"; do
  stage_fixture "$allowed_path"
done

check_tracked_sensitive_artifacts "$fixture_repo" \
  || fail 'Allowed lock, example, and Terraform source files were rejected.'

assert_rejected() {
  local path="$1" output

  stage_fixture "$path"
  if output="$(check_tracked_sensitive_artifacts "$fixture_repo" 2>&1)"; then
    fail "Tracked sensitive artifact was accepted: $path"
  fi
  case "$output" in
    *"$path"*) ;;
    *) fail "Rejection did not identify the tracked path: $path" ;;
  esac
  git -C "$fixture_repo" rm --cached --quiet -- "$path"
}

denied_paths=(
  infra/terraform/local/terraform.tfstate
  infra/terraform/local/terraform.tfstate.backup
  infra/terraform/local/terraform.tfstate.20260817.backup
  infra/terraform/vps/production.tfvars
  infra/terraform/vps/production.tfvars.backup
  infra/terraform/vps/production.auto.tfvars
  infra/terraform/vps/production.auto.tfvars.json
  infra/terraform/vps/crash.log
  infra/terraform/vps/crash.log.backup
  infra/terraform/vps/crash.20260817.log
  infra/terraform/vps/backend.hcl
  infra/terraform/vps/backend.hcl.backup
  infra/terraform/vps/production.backend.hcl
  infra/terraform/vps/production.tfbackend
  infra/terraform/vps/production.tfbackend.backup
  infra/terraform/vps/tfplan
  infra/terraform/vps/release.tfplan
  infra/terraform/vps/release.tfplan.json
  "infra/terraform/vps/release secret.tfplan"
)

for denied_path in "${denied_paths[@]}"; do
  assert_rejected "$denied_path"
done

echo 'Tracked Terraform artifact regression tests passed.'
