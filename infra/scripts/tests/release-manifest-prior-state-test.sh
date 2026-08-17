#!/usr/bin/env bash

set -euo pipefail

command -v terraform >/dev/null 2>&1 || {
  echo 'FAIL: terraform is required for the saved-plan prior-state regression test.' >&2
  exit 1
}
command -v jq >/dev/null 2>&1 || {
  echo 'FAIL: jq is required for the saved-plan prior-state regression test.' >&2
  exit 1
}

test_root="$(mktemp -d "${TMPDIR:-/tmp}/apollo-release-prior-state.XXXXXX")"
cleanup() {
  rm -rf -- "$test_root"
}
trap cleanup EXIT

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

cat > "$test_root/main.tf" <<'HCL'
terraform {
  required_version = "~> 1.15.0"
}

variable "release_manifest" {
  type = object({
    platform = object({
      image         = string
      source_commit = string
    })
  })
}

resource "terraform_data" "release" {
  input = var.release_manifest
}

output "release_manifest" {
  value = var.release_manifest
}
HCL

old_digest=sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
new_digest=sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
old_commit=1111111111111111111111111111111111111111
new_commit=2222222222222222222222222222222222222222
old_release="{platform={image=\"ghcr.io/apollo-deploy/apollo-platform-api@$old_digest\",source_commit=\"$old_commit\"}}"
new_release="{platform={image=\"ghcr.io/apollo-deploy/apollo-platform-api@$new_digest\",source_commit=\"$new_commit\"}}"

terraform -chdir="$test_root" init -backend=false -input=false -no-color >/dev/null
terraform -chdir="$test_root" apply -auto-approve -input=false -no-color \
  -var="release_manifest=$old_release" >/dev/null
captured_release="$(terraform -chdir="$test_root" output -json release_manifest)"
terraform -chdir="$test_root" plan -input=false -no-color \
  -var="release_manifest=$new_release" -out="$test_root/release.tfplan" >/dev/null
printf '%s' "$captured_release" \
  | jq -e --arg old_digest "$old_digest" --arg old_commit "$old_commit" '
      .platform == {
        image: ("ghcr.io/apollo-deploy/apollo-platform-api@" + $old_digest),
        source_commit: $old_commit
      }
    ' >/dev/null \
  || fail 'Raw state output did not preserve the deployed release before planning.'
terraform -chdir="$test_root" show -json "$test_root/release.tfplan" \
  | jq -e \
      --arg new_digest "$new_digest" \
      --arg new_commit "$new_commit" '
        .prior_state.values.outputs.release_manifest.value.platform == {
          image: ("ghcr.io/apollo-deploy/apollo-platform-api@" + $new_digest),
          source_commit: $new_commit
        } and
        .variables.release_manifest.value.platform == {
          image: ("ghcr.io/apollo-deploy/apollo-platform-api@" + $new_digest),
          source_commit: $new_commit
        } and
        .planned_values.outputs.release_manifest.value.platform == {
          image: ("ghcr.io/apollo-deploy/apollo-platform-api@" + $new_digest),
          source_commit: $new_commit
        }
      ' >/dev/null \
  || fail 'Terraform no longer recomputes saved-plan prior_state outputs from the desired release; reassess the raw pre-plan capture guard.'

echo 'Pre-plan raw-state release capture regression tests passed.'
