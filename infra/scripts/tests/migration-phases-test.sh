#!/usr/bin/env bash

set -euo pipefail

test_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$test_dir/../../.." && pwd)"
validator="$repo_root/infra/scripts/lib/validate-migration-phases.sh"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/apollo-migration-phase-tests.XXXXXX")"

cleanup() {
  rm -rf -- "$test_root"
}
trap cleanup EXIT

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

/bin/bash "$validator" "$repo_root" "$repo_root/infra/migration-phases.tsv" >/dev/null

assert_manifest_phase() {
  local service="$1"
  local filename="$2"
  local expected_phase="$3"
  local actual_phase

  actual_phase="$(awk -F '\t' -v service="$service" -v filename="$filename" '
    $1 == service && $2 == filename { count += 1; phase = $3 }
    END { if (count == 1) print phase; else exit 1 }
  ' "$repo_root/infra/migration-phases.tsv")" \
    || fail "Missing unique phase for $service/$filename."
  [ "$actual_phase" = "$expected_phase" ] \
    || fail "$service/$filename must remain $expected_phase, found $actual_phase."
}

# These historical Signal files contain cleanup mixed with otherwise additive
# work. Their bytes stay immutable and their cleanup must never cross back into
# the pre-deploy phase; migration 68 supplies the new release's additive column.
assert_manifest_phase signal 58_tracking_domain_uniqueness.psql contract
assert_manifest_phase signal 64_remove_project_tracking_domain.psql contract
assert_manifest_phase signal 65_domain_tracking_status.psql contract
assert_manifest_phase signal 68_domain_tracking_status_expand_bridge.psql expand
assert_manifest_phase signal 69_domain_tracking_status_bridge_cleanup.psql contract

for contract_filename in \
  58_tracking_domain_uniqueness.psql \
  64_remove_project_tracking_domain.psql \
  65_domain_tracking_status.psql \
  69_domain_tracking_status_bridge_cleanup.psql; do
  candidate="$test_root/real-${contract_filename%.psql}-expand.tsv"
  awk -F '\t' -v OFS='\t' -v filename="$contract_filename" '
    $1 == "signal" && $2 == filename { $3 = "expand" }
    { print }
  ' "$repo_root/infra/migration-phases.tsv" > "$candidate"
  if /bin/bash "$validator" "$repo_root" "$candidate" >/dev/null 2>&1; then
    fail "Real destructive migration signal/$contract_filename was accepted as expand."
  fi
done

bridge_migration="$repo_root/apollo-signal-api/scripts/migrations/68_domain_tracking_status_expand_bridge.psql"
cleanup_migration="$repo_root/apollo-signal-api/scripts/migrations/69_domain_tracking_status_bridge_cleanup.psql"
grep -Fq "NEW.verification_records := jsonb_set(" "$bridge_migration" \
  || fail 'Signal bridge does not mirror new column updates into legacy JSON.'
grep -Fq "NEW.tracking_status := legacy_status;" "$bridge_migration" \
  || fail 'Signal bridge does not mirror legacy JSON updates into the new column.'
grep -Fq "NEW.tracking_status IS DISTINCT FROM OLD.tracking_status" "$bridge_migration" \
  || fail 'Signal bridge does not distinguish replacement-release column writes.'
grep -Fq "OLD.verification_records #>> '{trackingCname,status}'" "$bridge_migration" \
  || fail 'Signal bridge does not distinguish legacy-release JSON writes.'
grep -Eq '^BEGIN;$' "$cleanup_migration" \
  || fail 'Signal bridge cleanup is not transactional.'
grep -Eq '^COMMIT;$' "$cleanup_migration" \
  || fail 'Signal bridge cleanup does not commit its transaction.'
cleanup_update_line="$(grep -n '^UPDATE domains$' "$cleanup_migration" | cut -d: -f1)"
cleanup_trigger_line="$(grep -n '^DROP TRIGGER ' "$cleanup_migration" | cut -d: -f1)"
cleanup_function_line="$(grep -n '^DROP FUNCTION ' "$cleanup_migration" | cut -d: -f1)"
[ -n "$cleanup_update_line" ] \
  && [ "$cleanup_update_line" -lt "$cleanup_trigger_line" ] \
  && [ "$cleanup_trigger_line" -lt "$cleanup_function_line" ] \
  || fail 'Signal bridge cleanup must remove compatibility data before its trigger and function.'

fixture="$test_root/repo"
mkdir -p \
  "$fixture/apollo-platform-api/scripts/migrations" \
  "$fixture/apollo-signal-api/scripts/migrations" \
  "$fixture/apollo-billing-api/scripts/migrations" \
  "$fixture/infra"
printf '%s\n' 'CREATE TABLE safe_table (id bigint);' \
  > "$fixture/apollo-platform-api/scripts/migrations/01_safe.psql"
printf '%s\n' 'DROP TABLE retired_table;' \
  > "$fixture/apollo-signal-api/scripts/migrations/02_contract.psql"
printf '%s\n' 'CREATE INDEX billing_index ON billing_table (id);' \
  > "$fixture/apollo-billing-api/scripts/migrations/03_safe.psql"
printf '%s\n' 'DROP INDEX IF EXISTS retired_index;' \
  > "$fixture/apollo-signal-api/scripts/migrations/04_drop_index.psql"
printf '%s\n' \
  'UPDATE projects' \
  "SET tracking_settings = tracking_settings - 'trackingDomain';" \
  > "$fixture/apollo-signal-api/scripts/migrations/05_json_key_delete.psql"
printf '%s\n' \
  'ALTER TABLE domains ADD COLUMN IF NOT EXISTS tracking_status text;' \
  'UPDATE domains SET tracking_status = '\''pending'\'';' \
  "UPDATE domains SET verification_records = verification_records #- '{trackingCname,status}';" \
  > "$fixture/apollo-signal-api/scripts/migrations/06_mixed_status_move.psql"
manifest="$fixture/infra/migration-phases.tsv"
printf '%s\t%s\t%s\n' \
  platform 01_safe.psql expand \
  signal 02_contract.psql contract \
  signal 04_drop_index.psql contract \
  signal 05_json_key_delete.psql contract \
  signal 06_mixed_status_move.psql contract \
  billing 03_safe.psql expand \
  > "$manifest"

/bin/bash "$validator" "$fixture" "$manifest" >/dev/null \
  || fail 'A complete, safely classified migration fixture was rejected.'

sed '/billing/d' "$manifest" > "$test_root/missing.tsv"
if /bin/bash "$validator" "$fixture" "$test_root/missing.tsv" >/dev/null 2>&1; then
  fail 'A migration missing from the phase manifest was accepted.'
fi

sed 's/signal\t02_contract.psql\tcontract/signal\t02_contract.psql\texpand/' \
  "$manifest" > "$test_root/destructive-expand.tsv"
if /bin/bash "$validator" "$fixture" "$test_root/destructive-expand.tsv" >/dev/null 2>&1; then
  fail 'Destructive SQL mislabeled as expand was accepted.'
fi

printf '%s\n' \
  'ALTER TABLE retired_table' \
  '  DROP COLUMN retired_value;' \
  > "$fixture/apollo-signal-api/scripts/migrations/02_contract.psql"
if /bin/bash "$validator" "$fixture" "$test_root/destructive-expand.tsv" >/dev/null 2>&1; then
  fail 'Multiline destructive SQL mislabeled as expand was accepted.'
fi

expect_expand_rejected() {
  local filename="$1"
  local description="$2"
  local candidate="$test_root/${filename%.psql}-expand.tsv"

  awk -F '\t' -v OFS='\t' -v filename="$filename" '
    $1 == "signal" && $2 == filename { $3 = "expand" }
    { print }
  ' "$manifest" > "$candidate"
  if /bin/bash "$validator" "$fixture" "$candidate" >/dev/null 2>&1; then
    fail "$description mislabeled as expand was accepted."
  fi
}

expect_expand_rejected 04_drop_index.psql 'DROP INDEX'
expect_expand_rejected 05_json_key_delete.psql 'Destructive JSON-key UPDATE'
expect_expand_rejected 06_mixed_status_move.psql 'Mixed additive/destructive migration'

cp "$manifest" "$test_root/duplicate.tsv"
printf '%s\t%s\t%s\n' platform 01_safe.psql expand >> "$test_root/duplicate.tsv"
if /bin/bash "$validator" "$fixture" "$test_root/duplicate.tsv" >/dev/null 2>&1; then
  fail 'A duplicate phase-manifest entry was accepted.'
fi

# The paired-index exception is bound to the exact reviewed Platform migration
# bytes, not merely to a filename or to superficially matching SQL.
printf '%s\n' \
  'DROP INDEX IF EXISTS idx_web_push_subscriptions_user;' \
  'CREATE INDEX idx_web_push_subscriptions_user ON web_push_subscriptions (id);' \
  'DROP INDEX IF EXISTS idx_web_push_subscriptions_delivery;' \
  'CREATE INDEX idx_web_push_subscriptions_delivery ON web_push_subscriptions (id);' \
  > "$fixture/apollo-platform-api/scripts/migrations/47_web_push_subscriptions.psql"
cp "$manifest" "$test_root/unreviewed-index-replacement.tsv"
printf '%s\t%s\t%s\n' platform 47_web_push_subscriptions.psql expand \
  >> "$test_root/unreviewed-index-replacement.tsv"
if /bin/bash "$validator" "$fixture" "$test_root/unreviewed-index-replacement.tsv" \
  >/dev/null 2>&1; then
  fail 'An unreviewed same-name DROP/CREATE INDEX replacement used the frozen exception.'
fi

echo 'Migration phase manifest regression tests passed.'
