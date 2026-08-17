#!/usr/bin/env bash

set -euo pipefail

audit_dir=${MIGRATION_TEST_AUDIT_DIR:?}
mode=${MIGRATION_TEST_MODE:-success}
require_lock=${MIGRATION_TEST_REQUIRE_LOCK:-false}

{
  printf 'call pid=%s' "$$"
  for argument in "$@"; do
    printf ' <%s>' "$argument"
  done
  printf '\n'
} >> "$audit_dir/argv.log"

if [ "${DB_PASS+x}" = x ] \
  || [ "${DB_PASS_B64+x}" = x ] \
  || [ "${PLATFORM_APP_DB_PASS+x}" = x ] \
  || [ "${BILLING_APP_DB_PASS+x}" = x ] \
  || [ "${BILLING_SUPERUSER_DB_PASS+x}" = x ] \
  || [ "${SIGNAL_APP_DB_PASS+x}" = x ] \
  || [ "${SIGNAL_SUPERUSER_DB_PASS+x}" = x ] \
  || [ "${PLATFORM_VERIFIER_DB_PASS+x}" = x ] \
  || [ "${db_pass_plaintext+x}" = x ] \
  || [ "${db_pass_b64+x}" = x ] \
  || [ "${platform_app_db_pass_plaintext+x}" = x ] \
  || [ "${platform_app_db_pass_b64+x}" = x ] \
  || [ "${billing_app_db_pass_plaintext+x}" = x ] \
  || [ "${billing_app_db_pass_b64+x}" = x ] \
  || [ "${billing_superuser_db_pass_plaintext+x}" = x ] \
  || [ "${billing_superuser_db_pass_b64+x}" = x ] \
  || [ "${signal_app_db_pass_plaintext+x}" = x ] \
  || [ "${signal_app_db_pass_b64+x}" = x ] \
  || [ "${signal_superuser_db_pass_plaintext+x}" = x ] \
  || [ "${signal_superuser_db_pass_b64+x}" = x ] \
  || [ "${platform_verifier_db_pass_plaintext+x}" = x ] \
  || [ "${platform_verifier_db_pass_b64+x}" = x ]; then
  printf 'plaintext-secret-environment-leak\n' >> "$audit_dir/events.log"
  exit 80
fi

case "$*" in
  *PASSWORD-*-SENTINEL*)
    printf 'plaintext-secret-argv-leak\n' >> "$audit_dir/events.log"
    exit 81
    ;;
esac

is_lock=false
case " $* " in
  *" lock_name="*) is_lock=true ;;
esac

IFS= read -r password_b64 || exit 82
printf 'password-frame-length=%s\n' "${#password_b64}" >> "$audit_dir/events.log"

if $is_lock; then
  printf 'lock-session-pid=%s\n' "$$" >> "$audit_dir/events.log"
  while ! mkdir "$audit_dir/advisory.lock" 2>/dev/null; do
    sleep 0.05
  done
  printf 'lock-pid=%s\n' "$$" >> "$audit_dir/events.log"

  # Invoked by the EXIT trap below.
  # shellcheck disable=SC2329
  release_fake_lock() {
    rmdir "$audit_dir/advisory.lock" 2>/dev/null || true
    printf 'lock-released pid=%s\n' "$$" >> "$audit_dir/events.log"
  }
  trap release_fake_lock EXIT

  while IFS= read -r sql_line; do
    if [[ "$sql_line" =~ ^SET\ lock_timeout\ =\ \'[0-9]+s\'\;$ ]]; then
      printf 'lock-timeout-exact\n' >> "$audit_dir/events.log"
    elif [ "$sql_line" = '\echo apollo-migration-lock-acquired' ]; then
      printf 'lock-marker-exact\n' >> "$audit_dir/events.log"
      printf '%s\n' 'apollo-migration-lock-acquired'
      if [ "$mode" = hang_lock ]; then
        printf 'lock-hanging pid=%s\n' "$$" >> "$audit_dir/events.log"
        trap '' INT TERM
        while :; do
          sleep 1
        done
      fi
    elif [ "$sql_line" = '\q' ]; then
      printf 'lock-quit-exact\n' >> "$audit_dir/events.log"
      exit 0
    elif [[ "$sql_line" == *cho* ]]; then
      printf 'lock-marker-malformed\n' >> "$audit_dir/events.log"
      exit 83
    fi
  done

  printf 'lock-input-ended-without-quit\n' >> "$audit_dir/events.log"
  exit 84
fi

stdin_payload=$(sed -n '1,1200p')
request="$*"
request="$request
$stdin_payload"

if $require_lock && [ ! -d "$audit_dir/advisory.lock" ]; then
  printf 'database-call-without-lock\n' >> "$audit_dir/events.log"
  exit 85
fi

case "$request" in
  *"SELECT 1 FROM pg_database"*)
    printf '1\n'
    ;;
  *"SELECT checksum FROM _"*"_migration_attempts"*)
    if [ -f "$audit_dir/incomplete" ]; then
      sed -n '1p' "$audit_dir/incomplete"
    fi
    ;;
  *"SELECT checksum FROM _"*"_migration_history"*)
    if [ -f "$audit_dir/history" ]; then
      sed -n '1p' "$audit_dir/history"
    fi
    ;;
  *"INSERT INTO _"*"_migration_attempts"*)
    checksum=$(printf '%s\n' "$request" \
      | sed -n "s/.*VALUES ('[^']*', '\([0-9a-f][0-9a-f]*\)', now(), NULL).*/\1/p" \
      | sed -n '1p')
    [ -n "$checksum" ] || exit 86
    printf '%s\n' "$checksum" > "$audit_dir/incomplete"
    printf 'attempt-started\n' >> "$audit_dir/events.log"
    ;;
  *"WITH completed_attempt AS"*)
    case "$request" in
      *"recorded AS ("*"RETURNING 1"*"SELECT 1 / count(*) AS migration_completion_recorded"*)
        printf 'completion-row-count-guard\n' >> "$audit_dir/events.log"
        ;;
      *)
        printf 'completion-row-count-guard-missing\n' >> "$audit_dir/events.log"
        exit 87
        ;;
    esac
    if [ "$mode" = tamper_completion ]; then
      rm -f "$audit_dir/incomplete"
    fi
    if [ ! -f "$audit_dir/incomplete" ]; then
      printf 'completion-row-count-guard-rejected-zero\n' >> "$audit_dir/events.log"
      exit 89
    fi
    mv "$audit_dir/incomplete" "$audit_dir/history"
    printf 'attempt-completed\n' >> "$audit_dir/events.log"
    ;;
  *"ROLE_TEST_MIGRATION"*)
    case "$stdin_payload" in
      *'\getenv platform_password APOLLO_PLATFORM_PASSWORD'*) ;;
      *) exit 88 ;;
    esac
    case "$stdin_payload" in
      *'\getenv verifier_password APOLLO_VERIFIER_PASSWORD'*) ;;
      *) exit 88 ;;
    esac
    printf 'role-migration-applied\n' >> "$audit_dir/events.log"
    ;;
  *"TEST_MIGRATION"*)
    printf 'migration-applied\n' >> "$audit_dir/events.log"
    if [ "$mode" = fail_migration ]; then
      exit 42
    fi
    ;;
esac

exit 0
