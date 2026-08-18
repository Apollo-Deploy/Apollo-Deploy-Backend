#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
file="$repo_root/infra/terraform/vps/migrations.tf"
grep -q 'from = module.deployment' "$file"
grep -q 'destroy = false' "$file"
[[ ! -e "$repo_root/infra/terraform/local" ]]
if rg -n 'resource "docker_|provider "docker"' "$repo_root/infra/terraform" -g '*.tf'; then
  echo 'FAIL: Terraform still declares a Docker resource or provider configuration.' >&2
  exit 1
fi
echo 'Terraform handoff tests passed.'
