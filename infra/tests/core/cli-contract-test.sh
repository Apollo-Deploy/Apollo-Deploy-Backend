#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
help="$(bash "$repo_root/infra/apollo" --help)"
for command in setup adopt up down migrate status logs deploy backup restore-check; do
  grep -q "$command" <<<"$help" || {
    echo "FAIL: CLI help omits $command" >&2
    exit 1
  }
done
if rg -n 'source .*\.env|eval[[:space:]]' "$repo_root/infra/apollo" "$repo_root/infra/lib"; then
  echo 'FAIL: CLI executes configuration as shell code.' >&2
  exit 1
fi
echo 'CLI contract tests passed.'
