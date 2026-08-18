#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
backup="$repo_root/infra/programs/backup.sh"
deploy="$repo_root/infra/programs/deploy-remote.sh"

grep -q 'pg_dumpall --no-password --quote-all-identifiers' "$backup"
if grep -q 'pg_dumpall .*--clean' "$backup"; then
  echo 'FAIL: backup dump contains a fresh-cluster-incompatible clean preamble.' >&2
  exit 1
fi
grep -Fq "\"\$release_root/programs/restore-check.sh\"" "$deploy"
grep -q 'failed isolated backup restore verification' "$deploy"
echo 'Backup restore-policy tests passed.'
