#!/usr/bin/env bash
# Reconcile database migrations, database grants, and Terraform-managed OAuth
# records after Terraform has created or updated the Docker/AWS infrastructure.
#
# The VPS transport is a private stdin-only primitive invoked by infra/setup.sh.
# Public hosted migration and OAuth operations must enter through the deployment
# wizard so identity, provenance, and the transaction lease are held. Contract
# execution belongs only to the separately governed external DBA/release system.
set -euo pipefail

# Capture the legacy local Terraform payload before any child process starts,
# then remove it from the inherited environment. VPS callers may not use this
# path at all; they must stream the protected payload through stdin.
ambient_reconcile_json_present=false
ambient_reconcile_json=""
if [ "${APOLLO_RECONCILE_JSON+x}" = x ]; then
  ambient_reconcile_json_present=true
  ambient_reconcile_json="$APOLLO_RECONCILE_JSON"
  unset APOLLO_RECONCILE_JSON
fi
# These names are never direct inputs to this orchestrator. Drop accidental
# ambient values before invoking any helper; selected credentials are decoded
# later into unexported variables from protected descriptors.
unset DB_PASS DB_PASS_B64 PGPASSWORD
unset PLATFORM_APP_DB_PASS BILLING_APP_DB_PASS BILLING_SUPERUSER_DB_PASS
unset SIGNAL_APP_DB_PASS SIGNAL_SUPERUSER_DB_PASS PLATFORM_VERIFIER_DB_PASS

usage() {
  echo "Usage: $0 <local|vps> [--phase <expand|contract|all>] [--roles <skip|reconcile>] [--migrations-only|--oauth-only]" >&2
}

if [ "$#" -lt 1 ]; then
  usage
  exit 2
fi

target="$1"
shift
migrations_only=false
oauth_only=false
migration_phase=all
phase_explicit=false
reconcile_db_roles=true
roles_explicit=false
case "$target" in
  local|vps) ;;
  *)
    usage
    exit 2
    ;;
esac

while [ "$#" -gt 0 ]; do
  case "$1" in
    --phase)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      migration_phase="$2"
      phase_explicit=true
      shift 2
      ;;
    --roles)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      case "$2" in
        skip) reconcile_db_roles=false ;;
        reconcile) reconcile_db_roles=true ;;
        *) usage; exit 2 ;;
      esac
      roles_explicit=true
      shift 2
      ;;
    --migrations-only) migrations_only=true; shift ;;
    --oauth-only) oauth_only=true; shift ;;
    *) usage; exit 2 ;;
  esac
done

$migrations_only && $oauth_only && {
  echo "ERROR: Choose only one reconciliation mode." >&2
  exit 2
}

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
terraform_root="$repo_root/infra/terraform/$target"
migration_runner="$script_dir/lib/run-migrations.sh"
signal_grants_runner="$script_dir/lib/apply-signal-grants.sh"
psql_stdin_runner="$script_dir/lib/run-psql-stdin.sh"
release_source_verifier="$script_dir/lib/verify-release-sources.sh"
oauth_renderer="$repo_root/infra/terraform/modules/docker/oauth-clients/scripts/render-sql.py"
migration_manifest="$repo_root/infra/migration-phases.tsv"
if [ "${APOLLO_MIGRATION_PHASE+x}" = x ] || [ "${APOLLO_RECONCILE_DB_ROLES+x}" = x ]; then
  echo "ERROR: Migration phase and role policy must be explicit command options, not ambient environment settings." >&2
  exit 2
fi

case "$migration_phase" in
  expand|contract|all) ;;
  *)
    echo "ERROR: Migration phase must be expand, contract, or all." >&2
    exit 2
    ;;
esac

case "$reconcile_db_roles" in
  true|false) ;;
  *)
    echo "ERROR: Role reconciliation policy must be true or false." >&2
    exit 2
    ;;
esac

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "ERROR: Required command is unavailable: $1" >&2
    exit 1
  fi
}

for command_name in python3 base64; do
  require_command "$command_name"
done

required_files=()
if ! $oauth_only; then
  required_files+=("$migration_runner" "$signal_grants_runner" "$migration_manifest")
fi
if ! $migrations_only; then
  required_files+=("$oauth_renderer" "$psql_stdin_runner")
fi
if [ "$target" = vps ]; then
  required_files+=("$release_source_verifier")
fi
for required_file in "${required_files[@]}"; do
  if [ ! -r "$required_file" ]; then
    echo "ERROR: Required reconciliation helper is not readable: $required_file" >&2
    exit 1
  fi
done

# Production pre-deploy orchestration streams its saved-plan payload through
# stdin so database credentials are never inherited in a child process's
# environment. Terraform's local provisioner still supplies its development
# payload through the environment to avoid re-entering Terraform while its
# local state lock is held. Manual invocations read the selected root output.
reconcile_from_stdin=false
if [ "$target" = vps ]; then
  [ "${APOLLO_RECONCILE_INTERNAL:-}" = setup-v1 ] || {
    echo "ERROR: VPS reconciliation is internal to infra/setup.sh." >&2
    exit 2
  }
  unset APOLLO_RECONCILE_INTERNAL
  if ! $phase_explicit || ! $roles_explicit; then
    echo "ERROR: VPS reconciliation requires explicit --phase and --roles options." >&2
    exit 2
  fi
  [ "$migration_phase" != all ] || {
    echo "ERROR: VPS reconciliation never combines expand and contract phases." >&2
    exit 2
  }
  [ "$migration_phase" = expand ] || {
    echo "ERROR: VPS contract migrations are not executable from this repository; use the separately governed DBA/release process." >&2
    exit 2
  }
  ! $ambient_reconcile_json_present || {
    echo "ERROR: VPS reconciliation accepts its protected payload through stdin only." >&2
    exit 2
  }
  reconcile_from_stdin=true
fi
if $reconcile_from_stdin; then
  reconcile_json="$(cat)"
  [ -n "$reconcile_json" ] || {
    echo "ERROR: Reconciliation JSON stdin payload is empty." >&2
    exit 2
  }
elif $ambient_reconcile_json_present; then
  reconcile_json="$ambient_reconcile_json"
  unset ambient_reconcile_json
else
  require_command terraform
  reconcile_json="$(terraform -chdir="$terraform_root" output -json reconcile)"
fi

decode_b64() {
  local encoded="$1"

  if printf '%s' "$encoded" | base64 --decode 2>/dev/null; then
    return
  fi
  printf '%s' "$encoded" | base64 -D
}

config_value() {
  local path="$1"
  local encoded

  encoded="$(printf '%s' "$reconcile_json" | python3 -c '
import base64
import json
import sys

value = json.load(sys.stdin)
for part in sys.argv[1].split("."):
    value = value[part]
if not isinstance(value, str):
    value = json.dumps(value, separators=(",", ":"))
sys.stdout.write(base64.b64encode(value.encode()).decode())
' "$path")"
  decode_b64 "$encoded"
}

encode_b64() {
  printf '%s' "$1" | base64 | tr -d '\n'
}

is_identifier() {
  [[ "$1" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]
}

is_container() {
  [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]]
}

verify_release_sources() {
  /bin/bash "$release_source_verifier" \
    platform "$repo_root/apollo-platform-api" "$platform_source_commit" \
    signal "$repo_root/apollo-signal-api" "$signal_source_commit" \
    billing "$repo_root/apollo-billing-api" "$billing_source_commit"
}

transport="$(config_value transport)"
platform_source_commit=""
signal_source_commit=""
billing_source_commit=""
if [ "$target" = vps ]; then
  platform_source_commit="$(config_value release.platform.source_commit)"
  signal_source_commit="$(config_value release.signal.source_commit)"
  billing_source_commit="$(config_value release.billing.source_commit)"
fi
db_container="$(config_value postgres_container)"
platform_container="$(config_value platform_container)"
billing_container="$(config_value billing_container)"
signal_container="$(config_value signal_container)"
enable_signal="$(config_value enable_signal)"
db_user="$(config_value database.user)"
db_pass="$(config_value database.password)"
db_name="$(config_value database.name)"
signal_db_name="$(config_value database.signal_name)"
platform_app_db_pass="$(config_value database.roles.platform_app)"
billing_app_db_pass="$(config_value database.roles.billing_app)"
billing_superuser_db_pass="$(config_value database.roles.billing_superuser)"
signal_app_db_pass="$(config_value database.roles.signal_app)"
signal_superuser_db_pass="$(config_value database.roles.signal_superuser)"
platform_verifier_db_pass="$(config_value database.roles.platform_verifier)"
oauth_clients_json=""
if ! $migrations_only; then
  oauth_clients_json="$(config_value oauth_clients)"
fi

for identifier in "$db_user" "$db_name" "$signal_db_name"; do
  if ! is_identifier "$identifier"; then
    echo "ERROR: Terraform output contains an unsafe PostgreSQL identifier." >&2
    exit 1
  fi
done

containers_to_validate=("$db_container")
if ! $migrations_only && ! $oauth_only; then
  containers_to_validate+=("$platform_container" "$billing_container")
fi
for container in "${containers_to_validate[@]}"; do
  if ! is_container "$container"; then
    echo "ERROR: Terraform output contains an unsafe Docker container name." >&2
    exit 1
  fi
done

if [ "$enable_signal" != "true" ] && [ "$enable_signal" != "false" ]; then
  echo "ERROR: Terraform output enable_signal must be true or false." >&2
  exit 1
fi
if ! $migrations_only && ! $oauth_only \
  && [ "$enable_signal" = "true" ] && ! is_container "$signal_container"; then
  echo "ERROR: Terraform output contains an unsafe Signal container name." >&2
  exit 1
fi

wait_for_local_health() {
  local container="$1"
  local attempts="$2"
  local interval="$3"
  local attempt status

  for attempt in $(seq 1 "$attempts"); do
    status="$(docker inspect --format='{{.State.Health.Status}}' "$container" 2>/dev/null || true)"
    if [ "$status" = "healthy" ]; then
      return
    fi
    echo "==> [$container] ${status:-missing}; retrying ($attempt/$attempts)..."
    sleep "$interval"
  done

  echo "ERROR: $container did not become healthy." >&2
  docker logs --tail 20 "$container" >&2 || true
  exit 1
}

run_local_migration() {
  local database_name="$1"
  local migrations_dir="$2"
  local service="$3"

  DB_CONTAINER="$db_container" \
    DB_USER="$db_user" \
    DB_NAME="$database_name" \
    MIGRATIONS_DIR="$migrations_dir" \
    MIGRATION_MANIFEST="$migration_manifest" \
    MIGRATION_PHASE="$migration_phase" \
    RECONCILE_DB_ROLES="$reconcile_db_roles" \
    SERVICE="$service" \
    /bin/bash -c '
set -euo pipefail
decode() {
  if printf "%s" "$1" | base64 --decode 2>/dev/null; then return; fi
  printf "%s" "$1" | base64 -D
}
IFS= read -r db_pass_b64 <&3
IFS= read -r platform_b64 <&3
IFS= read -r billing_b64 <&3
IFS= read -r billing_super_b64 <&3
IFS= read -r signal_b64 <&3
IFS= read -r signal_super_b64 <&3
IFS= read -r verifier_b64 <&3
DB_PASS="$(decode "$db_pass_b64")"
PLATFORM_APP_DB_PASS="$(decode "$platform_b64")"
BILLING_APP_DB_PASS="$(decode "$billing_b64")"
BILLING_SUPERUSER_DB_PASS="$(decode "$billing_super_b64")"
SIGNAL_APP_DB_PASS="$(decode "$signal_b64")"
SIGNAL_SUPERUSER_DB_PASS="$(decode "$signal_super_b64")"
PLATFORM_VERIFIER_DB_PASS="$(decode "$verifier_b64")"
unset db_pass_b64 platform_b64 billing_b64 billing_super_b64
unset signal_b64 signal_super_b64 verifier_b64
. "$1"
' apollo-migration "$migration_runner" 3< <(
      printf '%s\n' \
        "$(encode_b64 "$db_pass")" \
        "$(encode_b64 "$platform_app_db_pass")" \
        "$(encode_b64 "$billing_app_db_pass")" \
        "$(encode_b64 "$billing_superuser_db_pass")" \
        "$(encode_b64 "$signal_app_db_pass")" \
        "$(encode_b64 "$signal_superuser_db_pass")" \
        "$(encode_b64 "$platform_verifier_db_pass")"
    )
}

apply_local_signal_grants() {
  DB_CONTAINER="$db_container" \
    DB_USER="$db_user" \
    PLATFORM_DB_NAME="$db_name" \
    SIGNAL_DB_NAME="$signal_db_name" \
    GRANTS_FILE="$repo_root/apollo-platform-api/scripts/migrations/39b_signal_grants.psql" \
    /bin/bash -c '
set -euo pipefail
IFS= read -r db_pass_b64 <&3
if DB_PASS="$(printf "%s" "$db_pass_b64" | base64 --decode 2>/dev/null)"; then
  :
else
  DB_PASS="$(printf "%s" "$db_pass_b64" | base64 -D)"
fi
unset db_pass_b64
. "$1"
' apollo-signal-grants "$signal_grants_runner" \
      3< <(printf '%s\n' "$(encode_b64 "$db_pass")")
}

reconcile_local_oauth() {
  printf '%s' "$oauth_clients_json" \
    | python3 "$oauth_renderer" \
    | DB_CONTAINER="$db_container" \
      DB_USER="$db_user" \
      DB_NAME="$db_name" \
      /bin/bash -c '
set -euo pipefail
IFS= read -r DB_PASS_B64 <&3
. "$1"
' apollo-oauth "$psql_stdin_runner" \
        3< <(printf '%s\n' "$(encode_b64 "$db_pass")")
}

restart_local_services() {
  local containers=("$platform_container" "$billing_container")
  if [ "$enable_signal" = "true" ]; then
    containers+=("$signal_container")
  fi

  docker restart "${containers[@]}" >/dev/null
  wait_for_local_health "$platform_container" 80 5
  wait_for_local_health "$billing_container" 80 5
  if [ "$enable_signal" = "true" ]; then
    wait_for_local_health "$signal_container" 80 5
  fi
}

reconcile_local() {
  require_command docker
  wait_for_local_health "$db_container" 60 3
  if $oauth_only; then
    reconcile_local_oauth
    return
  fi

  run_local_migration "$db_name" "$repo_root/apollo-platform-api/scripts/migrations" platform

  if [ "$enable_signal" = "true" ]; then
    run_local_migration "$signal_db_name" "$repo_root/apollo-signal-api/scripts/migrations" signal
    apply_local_signal_grants
  fi

  run_local_migration "$db_name" "$repo_root/apollo-billing-api/scripts/migrations" billing
  if ! $migrations_only; then
    reconcile_local_oauth
    restart_local_services
  fi
}

ssh_host=""
ssh_user=""
ssh_port=""
ssh_key_path=""
remote_stage=""
remote_payload=""
ssh_command=()

cleanup_remote_stage() {
  if [ -n "$remote_stage" ]; then
    "${ssh_command[@]}" "rm -rf -- '$remote_stage'" >/dev/null 2>&1 || true
  fi
}

trap cleanup_remote_stage EXIT

wait_for_remote_health() {
  local container="$1"
  local attempts="$2"
  local interval="$3"
  local attempt status

  for attempt in $(seq 1 "$attempts"); do
    status="$("${ssh_command[@]}" "docker inspect --format='{{.State.Health.Status}}' '$container'" 2>/dev/null || true)"
    if [ "$status" = "healthy" ]; then
      return
    fi
    echo "==> [$container] ${status:-missing}; retrying ($attempt/$attempts)..."
    sleep "$interval"
  done

  echo "ERROR: $container did not become healthy on the VPS." >&2
  "${ssh_command[@]}" "docker logs --tail 20 '$container'" >&2 || true
  exit 1
}

prepare_remote_stage() {
  remote_stage="$("${ssh_command[@]}" "umask 077 && mktemp -d /opt/apollo/reconcile.XXXXXX")"
  if [[ ! "$remote_stage" =~ ^/opt/apollo/reconcile\.[A-Za-z0-9]+$ ]]; then
    echo "ERROR: Refusing unexpected remote staging path: $remote_stage" >&2
    exit 1
  fi
  remote_payload="$remote_stage/reconcile.env"

  {
    printf 'DB_CONTAINER_B64=%s\n' "$(encode_b64 "$db_container")"
    printf 'DB_PASS_B64=%s\n' "$(encode_b64 "$db_pass")"
    printf 'DB_USER_B64=%s\n' "$(encode_b64 "$db_user")"
    printf 'PLATFORM_APP_DB_PASS_B64=%s\n' "$(encode_b64 "$platform_app_db_pass")"
    printf 'BILLING_APP_DB_PASS_B64=%s\n' "$(encode_b64 "$billing_app_db_pass")"
    printf 'BILLING_SUPERUSER_DB_PASS_B64=%s\n' "$(encode_b64 "$billing_superuser_db_pass")"
    printf 'SIGNAL_APP_DB_PASS_B64=%s\n' "$(encode_b64 "$signal_app_db_pass")"
    printf 'SIGNAL_SUPERUSER_DB_PASS_B64=%s\n' "$(encode_b64 "$signal_superuser_db_pass")"
    printf 'PLATFORM_VERIFIER_DB_PASS_B64=%s\n' "$(encode_b64 "$platform_verifier_db_pass")"
  } | "${ssh_command[@]}" \
    "umask 077; cat > '$remote_payload'; chmod 600 '$remote_payload'"
}

stage_remote_assets() {
  tar -C "$repo_root" -cf - \
    apollo-platform-api/scripts/migrations \
    apollo-signal-api/scripts/migrations \
    apollo-billing-api/scripts/migrations \
    infra/scripts/lib/run-migrations.sh \
    infra/scripts/lib/apply-signal-grants.sh \
    infra/scripts/lib/run-psql-stdin.sh \
    infra/migration-phases.tsv \
    | "${ssh_command[@]}" "tar -xf - -C '$remote_stage'"
}

run_remote_migration() {
  local database_name="$1"
  local migrations_dir="$2"
  local service="$3"
  local remote_runner="$remote_stage/infra/scripts/lib/run-migrations.sh"

  "${ssh_command[@]}" \
    "bash -s -- '$remote_runner' '$remote_payload' '$database_name' '$migrations_dir' '$service' '$migration_phase' '$reconcile_db_roles'" <<'REMOTE'
set -euo pipefail
runner="$1"
payload="$2"
DB_NAME="$3"
MIGRATIONS_DIR="$4"
SERVICE="$5"
MIGRATION_MANIFEST="${runner%/scripts/lib/run-migrations.sh}/migration-phases.tsv"
MIGRATION_PHASE="$6"
RECONCILE_DB_ROLES="$7"

case "$payload" in
  /opt/apollo/reconcile.*/reconcile.env) ;;
  *) echo "ERROR: Unsafe reconciliation payload path." >&2; exit 1 ;;
esac
[ -f "$payload" ] && [ ! -L "$payload" ] || {
  echo "ERROR: Reconciliation payload is unavailable." >&2
  exit 1
}
# shellcheck disable=SC1090
. "$payload"
decode() { printf '%s' "$1" | base64 --decode; }
DB_CONTAINER="$(decode "$DB_CONTAINER_B64")"
DB_PASS="$(decode "$DB_PASS_B64")"
DB_USER="$(decode "$DB_USER_B64")"
PLATFORM_APP_DB_PASS="$(decode "$PLATFORM_APP_DB_PASS_B64")"
BILLING_APP_DB_PASS="$(decode "$BILLING_APP_DB_PASS_B64")"
BILLING_SUPERUSER_DB_PASS="$(decode "$BILLING_SUPERUSER_DB_PASS_B64")"
SIGNAL_APP_DB_PASS="$(decode "$SIGNAL_APP_DB_PASS_B64")"
SIGNAL_SUPERUSER_DB_PASS="$(decode "$SIGNAL_SUPERUSER_DB_PASS_B64")"
PLATFORM_VERIFIER_DB_PASS="$(decode "$PLATFORM_VERIFIER_DB_PASS_B64")"
unset DB_CONTAINER_B64 DB_PASS_B64 DB_USER_B64
unset PLATFORM_APP_DB_PASS_B64 BILLING_APP_DB_PASS_B64
unset BILLING_SUPERUSER_DB_PASS_B64 SIGNAL_APP_DB_PASS_B64
unset SIGNAL_SUPERUSER_DB_PASS_B64 PLATFORM_VERIFIER_DB_PASS_B64
# shellcheck disable=SC1090
. "$runner"
REMOTE
}

apply_remote_signal_grants() {
  local remote_runner="$remote_stage/infra/scripts/lib/apply-signal-grants.sh"
  local grants_file="$remote_stage/apollo-platform-api/scripts/migrations/39b_signal_grants.psql"

  "${ssh_command[@]}" \
    "bash -s -- '$remote_runner' '$remote_payload' '$db_name' '$signal_db_name' '$grants_file'" <<'REMOTE'
set -euo pipefail
runner="$1"
payload="$2"
PLATFORM_DB_NAME="$3"
SIGNAL_DB_NAME="$4"
GRANTS_FILE="$5"

case "$payload" in
  /opt/apollo/reconcile.*/reconcile.env) ;;
  *) echo "ERROR: Unsafe reconciliation payload path." >&2; exit 1 ;;
esac
[ -f "$payload" ] && [ ! -L "$payload" ] || {
  echo "ERROR: Reconciliation payload is unavailable." >&2
  exit 1
}
# shellcheck disable=SC1090
. "$payload"
decode() { printf '%s' "$1" | base64 --decode; }
DB_CONTAINER="$(decode "$DB_CONTAINER_B64")"
DB_PASS="$(decode "$DB_PASS_B64")"
DB_USER="$(decode "$DB_USER_B64")"
unset DB_CONTAINER_B64 DB_PASS_B64 DB_USER_B64
# shellcheck disable=SC1090
. "$runner"
REMOTE
}

reconcile_remote_oauth() {
  local remote_command remote_runner
  remote_runner="$remote_stage/infra/scripts/lib/run-psql-stdin.sh"
  remote_command="set -euo pipefail; . '$remote_payload'; DB_CONTAINER=\$(printf '%s' \"\$DB_CONTAINER_B64\" | base64 --decode); DB_USER=\$(printf '%s' \"\$DB_USER_B64\" | base64 --decode); DB_NAME='$db_name'; unset DB_CONTAINER_B64 DB_USER_B64; . '$remote_runner'"

  printf '%s' "$oauth_clients_json" \
    | python3 "$oauth_renderer" \
    | "${ssh_command[@]}" "$remote_command"
}

restart_remote_services() {
  local remote_containers="'$platform_container' '$billing_container'"
  if [ "$enable_signal" = "true" ]; then
    remote_containers="$remote_containers '$signal_container'"
  fi

  "${ssh_command[@]}" "docker restart $remote_containers >/dev/null"
  wait_for_remote_health "$platform_container" 80 5
  wait_for_remote_health "$billing_container" 80 5
  if [ "$enable_signal" = "true" ]; then
    wait_for_remote_health "$signal_container" 80 5
  fi
}

reconcile_vps() {
  local known_host

  # This runs before SSH, staging, or any database call. Image digests are
  # operator-reviewed in Terraform; migrations must come from the exact clean
  # source commits recorded beside those digests, never an ambient worktree.
  verify_release_sources

  for command_name in ssh tar; do
    require_command "$command_name"
  done

  ssh_host="$(config_value vps.host)"
  ssh_user="$(config_value vps.user)"
  ssh_port="$(config_value vps.ssh_port)"
  ssh_key_path="$(config_value vps.ssh_key_path)"

  if [[ ! "$ssh_host" =~ ^([A-Za-z0-9][A-Za-z0-9.-]*|\[[0-9A-Fa-f:]+\])$ ]] \
    || [[ ! "$ssh_user" =~ ^[a-z_][a-z0-9_-]*$ ]] \
    || [[ ! "$ssh_port" =~ ^[0-9]+$ ]] \
    || ((ssh_port < 1 || ssh_port > 65535)); then
    echo "ERROR: Terraform output contains unsafe SSH settings." >&2
    exit 1
  fi

  if [[ "$ssh_key_path" == \~/* ]]; then
    ssh_key_path="$HOME/${ssh_key_path#\~/}"
  fi
  if [ ! -r "$ssh_key_path" ]; then
    echo "ERROR: SSH private key is not readable: $ssh_key_path" >&2
    exit 1
  fi

  ssh_command=(
    ssh
    -p "$ssh_port"
    -i "$ssh_key_path"
    -o BatchMode=yes
    -o StrictHostKeyChecking=yes
    "$ssh_user@$ssh_host"
  )

  known_host="$ssh_host"
  case "$known_host" in
    \[*\]) known_host="${known_host#\[}"; known_host="${known_host%\]}" ;;
  esac
  if [ "$ssh_port" != 22 ]; then
    known_host="[$known_host]:$ssh_port"
  fi
  if ! "${ssh_command[@]}" true; then
    echo "ERROR: Strict SSH host-key verification or authentication failed for $ssh_user@$ssh_host." >&2
    echo "       Verify the server fingerprint out of band and add the exact $known_host key to the default OpenSSH known_hosts before retrying." >&2
    exit 1
  fi

  wait_for_remote_health "$db_container" 60 3
  prepare_remote_stage
  stage_remote_assets
  if $oauth_only; then
    reconcile_remote_oauth
    return
  fi

  run_remote_migration "$db_name" "$remote_stage/apollo-platform-api/scripts/migrations" platform

  if [ "$enable_signal" = "true" ]; then
    run_remote_migration "$signal_db_name" "$remote_stage/apollo-signal-api/scripts/migrations" signal
    apply_remote_signal_grants
  fi

  run_remote_migration "$db_name" "$remote_stage/apollo-billing-api/scripts/migrations" billing
  if ! $migrations_only; then
    reconcile_remote_oauth
    restart_remote_services
  fi
}

case "$transport" in
  local)
    [ "$target" = "local" ] || {
      echo "ERROR: local reconciliation data must come from terraform/local." >&2
      exit 1
    }
    reconcile_local
    ;;
  ssh)
    [ "$target" = "vps" ] || {
      echo "ERROR: SSH reconciliation data must come from terraform/vps." >&2
      exit 1
    }
    reconcile_vps
    ;;
  *)
    echo "ERROR: Unsupported reconciliation transport: $transport" >&2
    exit 1
    ;;
esac

if $migrations_only; then
  echo "==> Migrations complete."
elif $oauth_only; then
  echo "==> OAuth clients reconciled."
else
  echo "==> Reconciliation complete."
fi
