#!/usr/bin/env bash

set -euo pipefail

test_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$test_dir/../../.." && pwd)
backup_module="$repo_root/infra/terraform/modules/docker/postgres-backup/main.tf"
test_root=$(mktemp -d "${TMPDIR:-/tmp}/apollo-backup-health-tests.XXXXXX")

cleanup() {
  rm -rf -- "$test_root"
}
trap cleanup EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_status() {
  local expected="$1" actual="$2" context="$3"
  [ "$expected" -eq "$actual" ] \
    || fail "$context: expected status $expected, got $actual"
}

extract_local_script() {
  local name="$1" destination="$2"
  awk -v name="$name" '
    $0 == "  " name " = <<-SCRIPT" { capture = 1; next }
    capture && $0 == "  SCRIPT" { exit }
    capture {
      sub(/^    /, "")
      print
    }
  ' "$backup_module" >"$destination"
  [ -s "$destination" ] || fail "Could not extract local.$name from the backup module."
}

backup_script="$test_root/backup.sh"
health_script="$test_root/health.sh"
extract_local_script backup_script "$backup_script.original"
extract_local_script healthcheck_script "$health_script.original"

backup_dir="$test_root/backups"
generation_dir="$test_root/generation"
mkdir -p "$backup_dir" "$generation_dir"
sed \
  -e "s#/backups#$backup_dir#g" \
  -e "s#/tmp/current-generation-success#$generation_dir/current-generation-success#g" \
  -e "s#/tmp/.current-generation-success.tmp#$generation_dir/.current-generation-success.tmp#g" \
  "$backup_script.original" >"$backup_script"
sed \
  -e "s#/backups#$backup_dir#g" \
  -e "s#/tmp/current-generation-success#$generation_dir/current-generation-success#g" \
  "$health_script.original" >"$health_script"
chmod 0700 "$backup_script" "$health_script"

fake_bin="$test_root/bin"
mkdir -p "$fake_bin"
cat >"$fake_bin/pg_dumpall" <<'FAKE_PG_DUMPALL'
#!/usr/bin/env bash
set -euo pipefail
if [ "${APOLLO_BACKUP_TEST_RESULT:-success}" = failure ]; then
  exit 42
fi
for argument in "$@"; do
  case "$argument" in
    --file=*) printf '%s\n' complete-dump >"${argument#--file=}" ;;
  esac
done
FAKE_PG_DUMPALL
cat >"$fake_bin/sleep" <<'FAKE_SLEEP'
#!/usr/bin/env bash
exit 99
FAKE_SLEEP
chmod 0700 "$fake_bin/pg_dumpall" "$fake_bin/sleep"

run_health() {
  local status
  set +e
  BACKUP_MAX_AGE_SECONDS=3600 bash "$health_script" >/dev/null 2>&1
  status=$?
  set -e
  return "$status"
}

fresh_epoch=$(date -u '+%s')
printf '%s\n' "$fresh_epoch" >"$backup_dir/.last-success"
rm -f -- "$generation_dir/current-generation-success"
if run_health; then
  fail 'A persistent success marker from an older container generation passed health.'
fi

printf '%s\n' "$((fresh_epoch - 1))" >"$generation_dir/current-generation-success"
if run_health; then
  fail 'A mismatched generation marker passed health.'
fi

printf '%s\n' "$fresh_epoch" >"$generation_dir/current-generation-success"
run_health || fail 'Matching fresh persistent and current-generation markers failed health.'

# A failed attempt must clear a stale ephemeral marker before pg_dumpall and
# must not let the persistent marker make the new container generation healthy.
printf '%s\n' "$fresh_epoch" >"$generation_dir/current-generation-success"
set +e
PATH="$fake_bin:$PATH" \
  APOLLO_BACKUP_TEST_RESULT=failure \
  BACKUP_INTERVAL_SECONDS=3600 \
  BACKUP_RETRY_INTERVAL_SECONDS=60 \
  BACKUP_RETENTION_COUNT=5 \
  bash "$backup_script" >"$test_root/failed-attempt.out" 2>&1
failed_status=$?
set -e
assert_status 99 "$failed_status" 'Failed backup test loop termination'
[ ! -e "$generation_dir/current-generation-success" ] \
  || fail 'A failed backup attempt retained the current-generation marker.'
if run_health; then
  fail 'A failed current-generation attempt passed health through persistent state.'
fi

# A successful attempt atomically publishes both the durable timestamp and the
# ephemeral proof for this container generation; the resulting health passes.
set +e
PATH="$fake_bin:$PATH" \
  APOLLO_BACKUP_TEST_RESULT=success \
  BACKUP_INTERVAL_SECONDS=3600 \
  BACKUP_RETRY_INTERVAL_SECONDS=60 \
  BACKUP_RETENTION_COUNT=5 \
  bash "$backup_script" >"$test_root/success-attempt.out" 2>&1
success_status=$?
set -e
assert_status 99 "$success_status" 'Successful backup test loop termination'
[ -r "$generation_dir/current-generation-success" ] \
  || fail 'A successful backup did not create the current-generation marker.'
[ "$(cat "$generation_dir/current-generation-success")" = "$(cat "$backup_dir/.last-success")" ] \
  || fail 'Successful backup markers do not identify the same attempt.'
run_health || fail 'A successful backup from the current generation failed health.'

echo 'PostgreSQL backup generation health tests passed.'
