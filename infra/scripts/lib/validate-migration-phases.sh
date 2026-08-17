#!/usr/bin/env bash

# Validate that every deployable migration has one explicit reviewed phase and
# that destructive SQL cannot be mislabeled as safe for a pre-deploy run.
set -euo pipefail
export LC_ALL=C

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
default_repo_root="$(cd "$script_dir/../../.." && pwd)"
repo_root="${1:-$default_repo_root}"
manifest="${2:-$repo_root/infra/migration-phases.tsv}"

if [ ! -f "$manifest" ] || [ -L "$manifest" ]; then
  echo "ERROR: Migration phase manifest is unavailable or unsafe: $manifest" >&2
  exit 1
fi

scratch_dir="$(mktemp -d "${TMPDIR:-/tmp}/apollo-migration-phase-check.XXXXXX")"
cleanup() {
  rm -rf -- "$scratch_dir"
}
trap cleanup EXIT

manifest_rows="$scratch_dir/manifest-rows.tsv"
manifest_keys="$scratch_dir/manifest-keys.tsv"
filesystem_keys="$scratch_dir/filesystem-keys.tsv"

awk -F '\t' '
  /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
  NF != 3 || $1 !~ /^(platform|signal|billing)$/ ||
    $2 !~ /^[A-Za-z0-9._-]+\.psql$/ || $3 !~ /^(expand|contract)$/ {
      printf "ERROR: Invalid migration phase row at line %d.\n", NR > "/dev/stderr"
      bad = 1
      next
    }
  { print $1 "\t" $2 "\t" $3 }
  END { if (bad) exit 1 }
' "$manifest" > "$manifest_rows"

cut -f1,2 "$manifest_rows" | sort > "$manifest_keys"
if [ -n "$(uniq -d "$manifest_keys")" ]; then
  echo "ERROR: Migration phase manifest contains duplicate service/filename entries." >&2
  uniq -d "$manifest_keys" >&2
  exit 1
fi

for service in platform signal billing; do
  case "$service" in
    platform) migrations_dir="$repo_root/apollo-platform-api/scripts/migrations" ;;
    signal) migrations_dir="$repo_root/apollo-signal-api/scripts/migrations" ;;
    billing) migrations_dir="$repo_root/apollo-billing-api/scripts/migrations" ;;
  esac
  if [ ! -d "$migrations_dir" ]; then
    echo "ERROR: Migration directory is missing: $migrations_dir" >&2
    exit 1
  fi
  find "$migrations_dir" -maxdepth 1 -type f -name '*.psql' -print \
    | while IFS= read -r migration_file; do
        printf '%s\t%s\n' "$service" "${migration_file##*/}"
      done
done | sort > "$filesystem_keys"

if ! diff -u "$filesystem_keys" "$manifest_keys" >/dev/null; then
  echo "ERROR: Migration phase manifest does not exactly cover the checked-out migrations." >&2
  diff -u "$filesystem_keys" "$manifest_keys" >&2 || true
  exit 1
fi

# These deliberately conservative expressions catch obvious operations that
# can remove or rename data/schema still used by the previous release. They are
# a review backstop, not a SQL parser: semantic compatibility still has to be
# established when assigning every manifest phase. False positives are resolved
# by classifying the migration as contract, never by weakening this gate.
destructive_schema_sql='(^|[^[:alnum:]_])(drop[[:space:]]+(table|column|index|type|view|materialized[[:space:]]+view|schema)|alter[[:space:]]+table[^;]*(drop[[:space:]]+column|rename[[:space:]]+(column|to))|truncate([[:space:]]+table)?[[:space:]]|delete[[:space:]]+from)([^[:alnum:]_]|$)'
destructive_json_update_sql="(^|[^[:alnum:]_])update[[:space:]][^;]*set[[:space:]][^;]*=[^;]*(#[[:space:]]*-[[:space:]]*|[[:space:]]-[[:space:]]*)('|array[[:space:]]*\\[)"

file_sha256() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{ print $1 }'
  else
    sha256sum "$1" | awk '{ print $1 }'
  fi
}

is_reviewed_expand_exception() {
  local service="$1"
  local filename="$2"
  local migration_file="$3"
  local flattened_sql checksum index_name

  # This historical Platform migration replaces two performance indexes under
  # the same names inside one transaction. Commit leaves both old and new code
  # with the indexes; rollback restores the prior definitions. Freeze the exact
  # reviewed bytes and pairs so this cannot become a general DROP INDEX escape.
  [ "$service/$filename" = 'platform/47_web_push_subscriptions.psql' ] || return 1
  checksum="$(file_sha256 "$migration_file")"
  [ "$checksum" = '40b520d834c9412a21c81a2e46b4dfde46255417c9e652dfd4a0b66f9f1b96fa' ] \
    || return 1
  flattened_sql="$(LC_ALL=C tr '\r\n\t' '   ' < "$migration_file")"
  [ "$(printf '%s\n' "$flattened_sql" | grep -Eio 'drop[[:space:]]+index' | wc -l | tr -d '[:space:]')" = 2 ] \
    || return 1
  for index_name in idx_web_push_subscriptions_user idx_web_push_subscriptions_delivery; do
    printf '%s\n' "$flattened_sql" \
      | grep -Ei "drop[[:space:]]+index[[:space:]]+if[[:space:]]+exists[[:space:]]+${index_name}[[:space:]]*;[[:space:]]*create[[:space:]]+index[[:space:]]+${index_name}([^[:alnum:]_]|$)" \
      >/dev/null || return 1
  done
}

while IFS=$'\t' read -r service filename phase; do
  [ "$phase" = expand ] || continue
  case "$service" in
    platform) migration_file="$repo_root/apollo-platform-api/scripts/migrations/$filename" ;;
    signal) migration_file="$repo_root/apollo-signal-api/scripts/migrations/$filename" ;;
    billing) migration_file="$repo_root/apollo-billing-api/scripts/migrations/$filename" ;;
  esac
  # grep must consume the complete stream: under pipefail, `grep -q` can close
  # early, SIGPIPE `tr`, and accidentally convert a match into a non-match.
  if LC_ALL=C tr '\r\n\t' '   ' < "$migration_file" \
    | grep -Ei "$destructive_schema_sql|$destructive_json_update_sql" \
      >/dev/null; then
    if is_reviewed_expand_exception "$service" "$filename" "$migration_file"; then
      continue
    fi
    echo "ERROR: Destructive migration is classified as expand: $service/$filename" >&2
    exit 1
  fi
done < "$manifest_rows"

echo "Migration phase manifest is complete and fail-closed."
