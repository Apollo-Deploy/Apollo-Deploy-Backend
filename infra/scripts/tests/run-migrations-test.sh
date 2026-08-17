#!/usr/bin/env bash

set -euo pipefail

test_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$test_dir/../../.." && pwd)
migration_runner="$repo_root/infra/scripts/lib/run-migrations.sh"
psql_stdin_runner="$repo_root/infra/scripts/lib/run-psql-stdin.sh"
grants_runner="$repo_root/infra/scripts/lib/apply-signal-grants.sh"
test_root=$(mktemp -d "${TMPDIR:-/tmp}/apollo-migration-tests.XXXXXX")

cleanup() {
  rm -rf -- "$test_root"
}
trap cleanup EXIT

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

assert_contains() {
  local pattern="$1"
  local file="$2"
  grep -q -- "$pattern" "$file" || fail "Expected '$pattern' in $file"
}

assert_absent() {
  local pattern="$1"
  local file="$2"
  if grep -q -- "$pattern" "$file"; then
    fail "Did not expect '$pattern' in $file"
  fi
}

fake_bin="$test_root/bin"
mkdir -p "$fake_bin"
cp "$test_dir/migration-fake-docker.sh" "$fake_bin/docker"
chmod 0700 "$fake_bin/docker"
test_manifest="$test_root/migration-phases.tsv"
printf '%s\t%s\t%s\n' \
  signal 01_test.psql expand \
  signal 02_contract.psql contract \
  signal 03_unsafe.psql expand \
  signal 04_drop_index.psql expand \
  signal 05_json_key_delete.psql expand \
  signal 06_mixed_status_move.psql expand \
  signal 58_tracking_domain_uniqueness.psql contract \
  signal 64_remove_project_tracking_domain.psql contract \
  signal 65_domain_tracking_status.psql contract \
  signal 68_domain_tracking_status_expand_bridge.psql expand \
  signal 69_domain_tracking_status_bridge_cleanup.psql contract \
  platform 39_db_roles.psql expand \
  platform 47_web_push_subscriptions.psql expand \
  > "$test_manifest"

run_signal_migration() {
  local audit_dir="$1"
  local mode="$2"
  local migrations_dir="$3"
  local lock_timeout_seconds="${4:-3}"
  local migration_phase="${5:-all}"

  PATH="$fake_bin:$PATH" \
    TMPDIR="$audit_dir/tmp" \
    MIGRATION_TEST_AUDIT_DIR="$audit_dir" \
    MIGRATION_TEST_MODE="$mode" \
    MIGRATION_TEST_REQUIRE_LOCK=true \
    MIGRATION_LOCK_TIMEOUT_SECONDS="$lock_timeout_seconds" \
    DB_CONTAINER=audit-postgres \
    DB_PASS='DB-PASSWORD-RAW-SENTINEL' \
    DB_USER=postgres \
    DB_NAME=audit_db \
    MIGRATIONS_DIR="$migrations_dir" \
    MIGRATION_MANIFEST="$test_manifest" \
    MIGRATION_PHASE="$migration_phase" \
    SERVICE=signal \
    db_pass_plaintext='INHERITED-PLAINTEXT-SCRATCH-SENTINEL' \
    db_pass_b64='INHERITED-BASE64-SCRATCH-SENTINEL' \
    /bin/bash "$migration_runner"
}

run_platform_migration() {
  local audit_dir="$1"
  local mode="$2"
  local migrations_dir="$3"

  PATH="$fake_bin:$PATH" \
    TMPDIR="$audit_dir/tmp" \
    MIGRATION_TEST_AUDIT_DIR="$audit_dir" \
    MIGRATION_TEST_MODE="$mode" \
    MIGRATION_TEST_REQUIRE_LOCK=true \
    MIGRATION_LOCK_TIMEOUT_SECONDS=3 \
    DB_CONTAINER=audit-postgres \
    DB_PASS='DB-PASSWORD-RAW-SENTINEL' \
    DB_USER=postgres \
    DB_NAME=audit_db \
    MIGRATIONS_DIR="$migrations_dir" \
    MIGRATION_MANIFEST="$test_manifest" \
    MIGRATION_PHASE=expand \
    SERVICE=platform \
    /bin/bash "$migration_runner"
}

normal_dir="$test_root/normal"
normal_migrations="$normal_dir/migrations"
mkdir -p "$normal_dir/tmp" "$normal_migrations"
printf '%s\n' '-- TEST_MIGRATION' 'SELECT 1;' > "$normal_migrations/01_test.psql"
run_signal_migration "$normal_dir" success "$normal_migrations" > "$normal_dir/first.out" 2>&1
run_signal_migration "$normal_dir" success "$normal_migrations" > "$normal_dir/second.out" 2>&1
assert_contains 'lock-marker-exact' "$normal_dir/events.log"
assert_contains 'lock-timeout-exact' "$normal_dir/events.log"
assert_contains 'lock-quit-exact' "$normal_dir/events.log"
assert_contains 'attempt-started' "$normal_dir/events.log"
assert_contains 'attempt-completed' "$normal_dir/events.log"
assert_contains 'completion-row-count-guard' "$normal_dir/events.log"
[ "$(grep -c 'migration-applied' "$normal_dir/events.log")" -eq 1 ] \
  || fail 'A completed one-shot migration was replayed.'
assert_contains 'skipping (already applied): 01_test.psql' "$normal_dir/second.out"
assert_absent 'PASSWORD-RAW-SENTINEL' "$normal_dir/argv.log"
assert_absent 'secret-environment-leak' "$normal_dir/events.log"

incomplete_dir="$test_root/incomplete"
incomplete_migrations="$incomplete_dir/migrations"
mkdir -p "$incomplete_dir/tmp" "$incomplete_migrations"
printf '%s\n' '-- TEST_MIGRATION' 'SELECT 1;' > "$incomplete_migrations/01_test.psql"
if run_signal_migration "$incomplete_dir" fail_migration "$incomplete_migrations" \
  > "$incomplete_dir/first.out" 2>&1; then
  fail 'The injected migration failure unexpectedly succeeded.'
fi
if run_signal_migration "$incomplete_dir" success "$incomplete_migrations" \
  > "$incomplete_dir/second.out" 2>&1; then
  fail 'A started-but-incomplete migration was replayed.'
fi
assert_contains 'started-but-incomplete prior attempt' "$incomplete_dir/second.out"
[ "$(grep -c 'migration-applied' "$incomplete_dir/events.log")" -eq 1 ] \
  || fail 'The incomplete migration ran more than once.'

tampered_dir="$test_root/tampered"
tampered_migrations="$tampered_dir/migrations"
mkdir -p "$tampered_dir/tmp" "$tampered_migrations"
printf '%s\n' '-- TEST_MIGRATION' 'SELECT 1;' > "$tampered_migrations/01_test.psql"
if run_signal_migration "$tampered_dir" tamper_completion "$tampered_migrations" \
  > "$tampered_dir/run.out" 2>&1; then
  fail 'A migration with a missing completion-journal row unexpectedly succeeded.'
fi
assert_contains 'completion-row-count-guard-rejected-zero' "$tampered_dir/events.log"

role_dir="$test_root/role"
role_migrations="$role_dir/migrations"
mkdir -p "$role_dir/tmp" "$role_migrations"
printf '%s\n' '-- ROLE_TEST_MIGRATION' "SELECT :'platform_password';" \
  > "$role_migrations/39_db_roles.psql"
for run_number in 1 2; do
  PATH="$fake_bin:$PATH" \
    TMPDIR="$role_dir/tmp" \
    MIGRATION_TEST_AUDIT_DIR="$role_dir" \
    MIGRATION_TEST_MODE=success \
    MIGRATION_TEST_REQUIRE_LOCK=true \
    DB_CONTAINER=audit-postgres \
    DB_PASS='DB-PASSWORD-RAW-SENTINEL' \
    DB_USER=postgres \
    DB_NAME=audit_db \
    MIGRATIONS_DIR="$role_migrations" \
    MIGRATION_MANIFEST="$test_manifest" \
    MIGRATION_PHASE=all \
    SERVICE=platform \
    PLATFORM_APP_DB_PASS='PLATFORM-PASSWORD-RAW-SENTINEL' \
    BILLING_APP_DB_PASS='BILLING-PASSWORD-RAW-SENTINEL' \
    BILLING_SUPERUSER_DB_PASS='BILLING-SUPER-PASSWORD-RAW-SENTINEL' \
    SIGNAL_APP_DB_PASS='SIGNAL-PASSWORD-RAW-SENTINEL' \
    SIGNAL_SUPERUSER_DB_PASS='SIGNAL-SUPER-PASSWORD-RAW-SENTINEL' \
    PLATFORM_VERIFIER_DB_PASS='VERIFIER-PASSWORD-RAW-SENTINEL' \
    platform_app_db_pass_plaintext='INHERITED-PLAINTEXT-SCRATCH-SENTINEL' \
    platform_app_db_pass_b64='INHERITED-BASE64-SCRATCH-SENTINEL' \
    billing_app_db_pass_plaintext='INHERITED-PLAINTEXT-SCRATCH-SENTINEL' \
    billing_app_db_pass_b64='INHERITED-BASE64-SCRATCH-SENTINEL' \
    billing_superuser_db_pass_plaintext='INHERITED-PLAINTEXT-SCRATCH-SENTINEL' \
    billing_superuser_db_pass_b64='INHERITED-BASE64-SCRATCH-SENTINEL' \
    signal_app_db_pass_plaintext='INHERITED-PLAINTEXT-SCRATCH-SENTINEL' \
    signal_app_db_pass_b64='INHERITED-BASE64-SCRATCH-SENTINEL' \
    signal_superuser_db_pass_plaintext='INHERITED-PLAINTEXT-SCRATCH-SENTINEL' \
    signal_superuser_db_pass_b64='INHERITED-BASE64-SCRATCH-SENTINEL' \
    platform_verifier_db_pass_plaintext='INHERITED-PLAINTEXT-SCRATCH-SENTINEL' \
    platform_verifier_db_pass_b64='INHERITED-BASE64-SCRATCH-SENTINEL' \
    /bin/bash "$migration_runner" > "$role_dir/run-$run_number.out" 2>&1
done
[ "$(grep -c 'role-migration-applied' "$role_dir/events.log")" -eq 2 ] \
  || fail '39_db_roles.psql did not preserve its intentional rerun semantics.'

PATH="$fake_bin:$PATH" \
  TMPDIR="$role_dir/tmp" \
  MIGRATION_TEST_AUDIT_DIR="$role_dir" \
  MIGRATION_TEST_MODE=success \
  MIGRATION_TEST_REQUIRE_LOCK=true \
  DB_CONTAINER=audit-postgres \
  DB_PASS='DB-PASSWORD-ROTATION-GUARD-SENTINEL' \
  DB_USER=postgres \
  DB_NAME=audit_db \
  MIGRATIONS_DIR="$role_migrations" \
  MIGRATION_MANIFEST="$test_manifest" \
  MIGRATION_PHASE=expand \
  RECONCILE_DB_ROLES=false \
  SERVICE=platform \
  PLATFORM_APP_DB_PASS='ROTATED-PLATFORM-PASSWORD-SENTINEL' \
  BILLING_APP_DB_PASS='ROTATED-BILLING-PASSWORD-SENTINEL' \
  BILLING_SUPERUSER_DB_PASS='ROTATED-BILLING-SUPER-PASSWORD-SENTINEL' \
  SIGNAL_APP_DB_PASS='ROTATED-SIGNAL-PASSWORD-SENTINEL' \
  SIGNAL_SUPERUSER_DB_PASS='ROTATED-SIGNAL-SUPER-PASSWORD-SENTINEL' \
  PLATFORM_VERIFIER_DB_PASS='ROTATED-VERIFIER-PASSWORD-SENTINEL' \
  /bin/bash "$migration_runner" > "$role_dir/skipped.out" 2>&1
[ "$(grep -c 'role-migration-applied' "$role_dir/events.log")" -eq 2 ] \
  || fail 'The pre-apply role guard mutated scoped database credentials.'
assert_contains 'deferring database-role credential reconciliation' "$role_dir/skipped.out"
assert_absent 'PASSWORD-RAW-SENTINEL' "$role_dir/argv.log"
assert_absent 'secret-environment-leak' "$role_dir/events.log"

hang_dir="$test_root/hang"
hang_migrations="$hang_dir/migrations"
mkdir -p "$hang_dir/tmp" "$hang_migrations"
started_at=$(date +%s)
run_signal_migration "$hang_dir" hang_lock "$hang_migrations" > "$hang_dir/run.out" 2>&1
elapsed=$(( $(date +%s) - started_at ))
[ "$elapsed" -lt 8 ] || fail 'A stalled lock session caused unbounded cleanup.'
lock_pid=$(sed -n 's/^lock-pid=//p' "$hang_dir/events.log" | sed -n '1p')
[ -n "$lock_pid" ] || fail 'The fake lock PID was not recorded.'
if kill -0 "$lock_pid" 2>/dev/null; then
  fail 'The bounded cleanup left the direct lock-session process running.'
fi

contended_dir="$test_root/contended"
contended_migrations="$contended_dir/migrations"
mkdir -p "$contended_dir/tmp" "$contended_migrations" "$contended_dir/advisory.lock"
printf '%s\n' '-- TEST_MIGRATION' 'SELECT 1;' > "$contended_migrations/01_test.psql"
started_at=$(date +%s)
if run_signal_migration "$contended_dir" success "$contended_migrations" 1 \
  > "$contended_dir/run.out" 2>&1; then
  fail 'A pre-held advisory lock unexpectedly allowed migration execution.'
fi
elapsed=$(( $(date +%s) - started_at ))
[ "$elapsed" -lt 6 ] || fail 'Advisory-lock contention was not bounded.'
assert_contains 'Timed out after 1 seconds waiting for the PostgreSQL migration lock' \
  "$contended_dir/run.out"
contended_pid=$(sed -n 's/^lock-session-pid=//p' "$contended_dir/events.log" | sed -n '1p')
[ -n "$contended_pid" ] || fail 'The contended fake lock-session PID was not recorded.'
if kill -0 "$contended_pid" 2>/dev/null; then
  fail 'The timed-out advisory-lock client was left running.'
fi
rmdir "$contended_dir/advisory.lock"

deferred_dir="$test_root/deferred-contract"
deferred_migrations="$deferred_dir/migrations"
mkdir -p "$deferred_dir/tmp" "$deferred_migrations"
printf '%s\n' '-- TEST_MIGRATION' 'DROP TABLE retired_table;' \
  > "$deferred_migrations/02_contract.psql"
run_signal_migration "$deferred_dir" success "$deferred_migrations" 3 expand \
  > "$deferred_dir/run.out" 2>&1
assert_contains 'deferring contract migration' "$deferred_dir/run.out"
assert_absent 'migration-applied' "$deferred_dir/events.log"

contract_dir="$test_root/contract"
contract_migrations="$contract_dir/migrations"
mkdir -p "$contract_dir/tmp" "$contract_migrations"
printf '%s\n' '-- TEST_MIGRATION' 'DROP TABLE retired_table;' \
  > "$contract_migrations/02_contract.psql"
run_signal_migration "$contract_dir" success "$contract_migrations" 3 contract \
  > "$contract_dir/run.out" 2>&1
assert_contains 'migration-applied' "$contract_dir/events.log"

unsafe_dir="$test_root/unsafe-expand"
unsafe_migrations="$unsafe_dir/migrations"
mkdir -p "$unsafe_dir/tmp" "$unsafe_migrations"
printf '%s\n' \
  '-- TEST_MIGRATION' \
  'ALTER TABLE retired_table' \
  '  DROP COLUMN retired_value;' \
  > "$unsafe_migrations/03_unsafe.psql"
# Keep enough trailing input to catch a pipefail/grep-early-exit bypass.
awk 'BEGIN { for (i = 0; i < 20000; i += 1) print "-- trailing reviewed SQL" }' \
  >> "$unsafe_migrations/03_unsafe.psql"
if run_signal_migration "$unsafe_dir" success "$unsafe_migrations" 3 expand \
  > "$unsafe_dir/run.out" 2>&1; then
  fail 'Destructive SQL mislabeled as expand reached migration execution.'
fi
assert_contains 'Destructive migration is classified as expand: signal/03_unsafe.psql' \
  "$unsafe_dir/run.out"
assert_absent 'migration-applied' "$unsafe_dir/events.log"

drop_index_dir="$test_root/drop-index-expand"
drop_index_migrations="$drop_index_dir/migrations"
mkdir -p "$drop_index_dir/tmp" "$drop_index_migrations"
printf '%s\n' '-- TEST_MIGRATION' 'DROP INDEX IF EXISTS retired_index;' \
  > "$drop_index_migrations/04_drop_index.psql"
if run_signal_migration "$drop_index_dir" success "$drop_index_migrations" 3 expand \
  > "$drop_index_dir/run.out" 2>&1; then
  fail 'DROP INDEX mislabeled as expand reached migration execution.'
fi
assert_contains 'Destructive migration is classified as expand: signal/04_drop_index.psql' \
  "$drop_index_dir/run.out"
assert_absent 'migration-applied' "$drop_index_dir/events.log"

json_delete_dir="$test_root/json-delete-expand"
json_delete_migrations="$json_delete_dir/migrations"
mkdir -p "$json_delete_dir/tmp" "$json_delete_migrations"
printf '%s\n' \
  '-- TEST_MIGRATION' \
  'UPDATE projects' \
  "SET tracking_settings = tracking_settings - 'trackingDomain' - 'trackingDomainStatus';" \
  > "$json_delete_migrations/05_json_key_delete.psql"
if run_signal_migration "$json_delete_dir" success "$json_delete_migrations" 3 expand \
  > "$json_delete_dir/run.out" 2>&1; then
  fail 'Destructive JSON-key UPDATE mislabeled as expand reached migration execution.'
fi
assert_contains 'Destructive migration is classified as expand: signal/05_json_key_delete.psql' \
  "$json_delete_dir/run.out"
assert_absent 'migration-applied' "$json_delete_dir/events.log"

mixed_dir="$test_root/mixed-expand"
mixed_migrations="$mixed_dir/migrations"
mkdir -p "$mixed_dir/tmp" "$mixed_migrations"
printf '%s\n' \
  '-- TEST_MIGRATION' \
  'ALTER TABLE domains ADD COLUMN IF NOT EXISTS tracking_status text;' \
  'UPDATE domains SET tracking_status = '\''pending'\'';' \
  "UPDATE domains SET verification_records = verification_records #- '{trackingCname,status}';" \
  > "$mixed_migrations/06_mixed_status_move.psql"
if run_signal_migration "$mixed_dir" success "$mixed_migrations" 3 expand \
  > "$mixed_dir/run.out" 2>&1; then
  fail 'Mixed additive/destructive migration mislabeled as expand reached migration execution.'
fi
assert_contains 'Destructive migration is classified as expand: signal/06_mixed_status_move.psql' \
  "$mixed_dir/run.out"
assert_absent 'migration-applied' "$mixed_dir/events.log"

signal_phase_dir="$test_root/signal-phase-boundary"
signal_phase_migrations="$signal_phase_dir/migrations"
mkdir -p "$signal_phase_dir/tmp" "$signal_phase_migrations"
printf '%s\n' '-- TEST_MIGRATION' 'SELECT 58;' \
  > "$signal_phase_migrations/58_tracking_domain_uniqueness.psql"
printf '%s\n' '-- TEST_MIGRATION' 'SELECT 64;' \
  > "$signal_phase_migrations/64_remove_project_tracking_domain.psql"
printf '%s\n' '-- TEST_MIGRATION' 'SELECT 65;' \
  > "$signal_phase_migrations/65_domain_tracking_status.psql"
printf '%s\n' '-- TEST_MIGRATION' 'ALTER TABLE domains ADD COLUMN IF NOT EXISTS tracking_status text;' \
  > "$signal_phase_migrations/68_domain_tracking_status_expand_bridge.psql"
printf '%s\n' '-- TEST_MIGRATION' 'SELECT 69;' \
  > "$signal_phase_migrations/69_domain_tracking_status_bridge_cleanup.psql"
run_signal_migration "$signal_phase_dir" success "$signal_phase_migrations" 3 expand \
  > "$signal_phase_dir/run.out" 2>&1
for contract_filename in \
  58_tracking_domain_uniqueness.psql \
  64_remove_project_tracking_domain.psql \
  65_domain_tracking_status.psql \
  69_domain_tracking_status_bridge_cleanup.psql; do
  assert_contains "deferring contract migration until after the immutable application release: $contract_filename" \
    "$signal_phase_dir/run.out"
  assert_absent "applying: $contract_filename" "$signal_phase_dir/run.out"
done
assert_contains 'applying: 68_domain_tracking_status_expand_bridge.psql' \
  "$signal_phase_dir/run.out"
[ "$(grep -c 'migration-applied' "$signal_phase_dir/events.log")" -eq 1 ] \
  || fail 'The expand phase did not execute only the additive Signal bridge.'

reviewed_index_dir="$test_root/reviewed-index-replacement"
reviewed_index_migrations="$reviewed_index_dir/migrations"
mkdir -p "$reviewed_index_dir/tmp" "$reviewed_index_migrations"
cp "$repo_root/apollo-platform-api/scripts/migrations/47_web_push_subscriptions.psql" \
  "$reviewed_index_migrations/47_web_push_subscriptions.psql"
run_platform_migration "$reviewed_index_dir" success "$reviewed_index_migrations" \
  > "$reviewed_index_dir/run.out" 2>&1
assert_contains 'applying: 47_web_push_subscriptions.psql' "$reviewed_index_dir/run.out"
assert_contains 'attempt-completed' "$reviewed_index_dir/events.log"

unreviewed_index_dir="$test_root/unreviewed-index-replacement"
unreviewed_index_migrations="$unreviewed_index_dir/migrations"
mkdir -p "$unreviewed_index_dir/tmp" "$unreviewed_index_migrations"
cp "$repo_root/apollo-platform-api/scripts/migrations/47_web_push_subscriptions.psql" \
  "$unreviewed_index_migrations/47_web_push_subscriptions.psql"
printf '%s\n' '-- checksum-changing unreviewed content' \
  >> "$unreviewed_index_migrations/47_web_push_subscriptions.psql"
if run_platform_migration "$unreviewed_index_dir" success "$unreviewed_index_migrations" \
  > "$unreviewed_index_dir/run.out" 2>&1; then
  fail 'A checksum-changed Platform index replacement used the runtime exception.'
fi
assert_contains 'Destructive migration is classified as expand: platform/47_web_push_subscriptions.psql' \
  "$unreviewed_index_dir/run.out"
assert_absent 'attempt-started' "$unreviewed_index_dir/events.log"

stdin_dir="$test_root/stdin"
mkdir -p "$stdin_dir"
encoded_db_pass_input=$(printf '%s' 'DB-PASSWORD-RAW-SENTINEL' | base64 | tr -d '\n')
printf '%s\n' 'SELECT 1;' \
  | PATH="$fake_bin:$PATH" \
    MIGRATION_TEST_AUDIT_DIR="$stdin_dir" \
    DB_CONTAINER=audit-postgres \
    DB_PASS_B64="$encoded_db_pass_input" \
    DB_USER=postgres \
    DB_NAME=audit_db \
    db_pass_b64='INHERITED-BASE64-SCRATCH-SENTINEL' \
    /bin/bash "$psql_stdin_runner"
assert_absent 'secret-environment-leak' "$stdin_dir/events.log"

grants_dir="$test_root/grants"
mkdir -p "$grants_dir"
printf '%s\n' 'SELECT 1;' > "$grants_dir/grants.psql"
PATH="$fake_bin:$PATH" \
  MIGRATION_TEST_AUDIT_DIR="$grants_dir" \
  DB_CONTAINER=audit-postgres \
  DB_PASS='DB-PASSWORD-RAW-SENTINEL' \
  DB_PASS_B64='INHERITED-BASE64-SCRATCH-SENTINEL' \
  db_pass_plaintext='INHERITED-PLAINTEXT-SCRATCH-SENTINEL' \
  DB_USER=postgres \
  PLATFORM_DB_NAME=platform_db \
  SIGNAL_DB_NAME=signal_db \
  GRANTS_FILE="$grants_dir/grants.psql" \
  /bin/bash "$grants_runner" > "$grants_dir/run.out" 2>&1
assert_absent 'secret-environment-leak' "$grants_dir/events.log"

echo 'Migration shell regression tests passed.'
