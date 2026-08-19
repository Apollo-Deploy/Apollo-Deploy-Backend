#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
grants_file="$repo_root/apollo-platform-api/scripts/migrations/39b_signal_grants.psql"

require_grant() {
  local statement="$1"
  grep -Fq "$statement" "$grants_file" || {
    printf 'FAIL: Signal grant reconciliation omits: %s\n' "$statement" >&2
    exit 1
  }
}

require_grant "GRANT USAGE ON SCHEMA public TO billing_superuser"
require_grant "GRANT SELECT ON projects, domains, webhook_endpoints TO billing_superuser"
require_grant \
  "GRANT SELECT (organization_id, usage_date, email_count) ON organization_usage_daily TO billing_superuser"
require_grant "GRANT USAGE ON SCHEMA public TO platform_verifier"
require_grant "GRANT SELECT ON projects TO platform_verifier"

if grep -Eq 'GRANT SELECT ON ALL TABLES .* (billing_superuser|platform_verifier)' "$grants_file"; then
  echo 'FAIL: Cross-service reader role received broad table access.' >&2
  exit 1
fi

echo 'Database role grant-policy tests passed.'
