#!/usr/bin/env bash
set -euo pipefail

PROGRAM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APOLLO_ROOT="$(cd "$PROGRAM_DIR/.." && pwd)"
# shellcheck source=../lib/common.sh
source "$APOLLO_ROOT/lib/common.sh"

for command_name in docker jq python3 base64; do
  require_command "$command_name"
done

phase="${1:-expand}"
case "$phase" in expand | contract | all) ;; *) die 'Migration phase must be expand, contract, or all.' ;; esac

secret_file="${APOLLO_SECRET_FILE:-$APOLLO_ROOT/config/secrets.env}"
migration_root="${APOLLO_MIGRATION_ROOT:-$APOLLO_ROOT/migrations}"
manifest="${APOLLO_MIGRATION_MANIFEST:-$APOLLO_ROOT/migration-phases.tsv}"
helper_dir="${APOLLO_HELPER_DIR:-$APOLLO_ROOT/scripts/lib}"
runner="$helper_dir/run-migrations.sh"
grants_runner="$helper_dir/apply-signal-grants.sh"

require_protected_file "$secret_file" 'Apollo secrets'
validate_env_file "$secret_file"
for file in "$manifest" "$runner" "$grants_runner"; do
  [[ -f "$file" && ! -L "$file" ]] || die "Migration artifact is unavailable or unsafe: $file"
done

run_service() {
  local service="$1"
  local database="$2"
  local directory="$migration_root/$service"
  if [[ ! -d "$directory" ]]; then
    case "$service" in
      platform) directory="$migration_root/apollo-platform-api/scripts/migrations" ;;
      signal) directory="$migration_root/apollo-signal-api/scripts/migrations" ;;
      billing) directory="$migration_root/apollo-billing-api/scripts/migrations" ;;
    esac
  fi
  DB_CONTAINER=apollo-platform-postgres \
    DB_USER=postgres \
    DB_PASS="$(env_value "$secret_file" POSTGRES_PASSWORD)" \
    DB_NAME="$database" \
    MIGRATIONS_DIR="$directory" \
    MIGRATION_MANIFEST="$manifest" \
    MIGRATION_PHASE="$phase" \
    RECONCILE_DB_ROLES=true \
    SERVICE="$service" \
    PLATFORM_APP_DB_PASS="$(env_value "$secret_file" PLATFORM_APP_DB_PASSWORD)" \
    PLATFORM_VERIFIER_DB_PASS="$(env_value "$secret_file" PLATFORM_VERIFIER_DB_PASSWORD)" \
    BILLING_APP_DB_PASS="$(env_value "$secret_file" BILLING_APP_DB_PASSWORD)" \
    BILLING_SUPERUSER_DB_PASS="$(env_value "$secret_file" BILLING_SUPERUSER_DB_PASSWORD)" \
    SIGNAL_APP_DB_PASS="$(env_value "$secret_file" SIGNAL_APP_DB_PASSWORD)" \
    SIGNAL_SUPERUSER_DB_PASS="$(env_value "$secret_file" SIGNAL_SUPERUSER_DB_PASSWORD)" \
    bash "$runner"
}

run_service platform apollo_deploy_platform
run_service signal apollo_deploy_signal

DB_CONTAINER=apollo-platform-postgres \
  DB_USER=postgres \
  DB_PASS="$(env_value "$secret_file" POSTGRES_PASSWORD)" \
  PLATFORM_DB_NAME=apollo_deploy_platform \
  SIGNAL_DB_NAME=apollo_deploy_signal \
  GRANTS_FILE="$(
    if [[ -f "$migration_root/platform/39b_signal_grants.psql" ]]; then
      printf '%s' "$migration_root/platform/39b_signal_grants.psql"
    else
      printf '%s' "$migration_root/apollo-platform-api/scripts/migrations/39b_signal_grants.psql"
    fi
  )" \
  bash "$grants_runner"

run_service billing apollo_deploy_platform

if [[ "$phase" != contract ]]; then
  APOLLO_SECRET_FILE="$secret_file" "$PROGRAM_DIR/oauth-reconcile.sh"
fi

info "Migration phase '$phase' completed."
