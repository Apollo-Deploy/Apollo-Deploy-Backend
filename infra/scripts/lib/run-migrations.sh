#!/usr/bin/env bash
# Idempotent service migrations against the Docker-managed PostgreSQL instance.
# Required environment: DB_CONTAINER, DB_PASS, DB_NAME, MIGRATIONS_DIR, SERVICE.
set -euo pipefail
export LC_ALL=C

DB_CONTAINER="${DB_CONTAINER:?ERROR: DB_CONTAINER is required}"
DB_PASS="${DB_PASS:?ERROR: DB_PASS is required}"
DB_USER="${DB_USER:-postgres}"
DB_NAME="${DB_NAME:?ERROR: DB_NAME is required}"
MIGRATIONS_DIR="${MIGRATIONS_DIR:?ERROR: MIGRATIONS_DIR is required}"
MIGRATION_MANIFEST="${MIGRATION_MANIFEST:?ERROR: MIGRATION_MANIFEST is required}"
MIGRATION_PHASE="${MIGRATION_PHASE:-all}"
RECONCILE_DB_ROLES="${RECONCILE_DB_ROLES:-true}"
SERVICE="${SERVICE:?ERROR: SERVICE is required (platform|signal|billing)}"
MIGRATION_LOCK_TIMEOUT_SECONDS="${MIGRATION_LOCK_TIMEOUT_SECONDS:-60}"

case "$SERVICE" in
  platform|signal|billing) ;;
  *)
    echo "ERROR: Unsupported service '$SERVICE'." >&2
    exit 1
    ;;
esac

case "$RECONCILE_DB_ROLES" in
  true|false) ;;
  *)
    echo "ERROR: RECONCILE_DB_ROLES must be true or false." >&2
    exit 1
    ;;
esac

case "$MIGRATION_PHASE" in
  expand|contract|all) ;;
  *)
    echo "ERROR: MIGRATION_PHASE must be expand, contract, or all." >&2
    exit 1
    ;;
esac

if [[ ! "$MIGRATION_LOCK_TIMEOUT_SECONDS" =~ ^[0-9]+$ ]] \
  || [ "$MIGRATION_LOCK_TIMEOUT_SECONDS" -lt 1 ] \
  || [ "$MIGRATION_LOCK_TIMEOUT_SECONDS" -gt 3600 ]; then
  echo "ERROR: MIGRATION_LOCK_TIMEOUT_SECONDS must be an integer from 1 through 3600." >&2
  exit 1
fi

for identifier in "$DB_USER" "$DB_NAME"; do
  if [[ ! "$identifier" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
    echo "ERROR: Unsafe PostgreSQL identifier '$identifier'." >&2
    exit 1
  fi
done

if [ ! -d "$MIGRATIONS_DIR" ]; then
  echo "ERROR: Migration directory does not exist: $MIGRATIONS_DIR" >&2
  exit 1
fi
if [ ! -f "$MIGRATION_MANIFEST" ] || [ -L "$MIGRATION_MANIFEST" ]; then
  echo "ERROR: Migration phase manifest is unavailable or unsafe: $MIGRATION_MANIFEST" >&2
  exit 1
fi

HISTORY_TABLE="_${SERVICE}_migration_history"
ATTEMPT_TABLE="_${SERVICE}_migration_attempts"
LOCK_NAME="apollo-migrations:${DB_NAME}"
LOCK_MARKER="apollo-migration-lock-acquired"
# Flatten SQL before matching so a reviewed multiline statement cannot hide an
# obvious destructive shape. These expressions are a conservative deployment
# backstop, not a SQL parser; semantic safety remains an explicit review duty.
# False positives are resolved by classifying the migration as contract.
DESTRUCTIVE_SCHEMA_SQL='(^|[^[:alnum:]_])(drop[[:space:]]+(table|column|index|type|view|materialized[[:space:]]+view|schema)|alter[[:space:]]+table[^;]*(drop[[:space:]]+column|rename[[:space:]]+(column|to))|truncate([[:space:]]+table)?[[:space:]]|delete[[:space:]]+from)([^[:alnum:]_]|$)'
DESTRUCTIVE_JSON_UPDATE_SQL="(^|[^[:alnum:]_])update[[:space:]][^;]*set[[:space:]][^;]*=[^;]*(#[[:space:]]*-[[:space:]]*|[[:space:]]-[[:space:]]*)('|array[[:space:]]*\\[)"

file_sha256() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{ print $1 }'
  else
    sha256sum "$1" | awk '{ print $1 }'
  fi
}

contains_destructive_sql() {
  # Do not use grep -q here: with pipefail, an early match can SIGPIPE `tr`
  # and turn a true match into a false pipeline result for a large file.
  LC_ALL=C tr '\r\n\t' '   ' < "$1" \
    | grep -Ei "$DESTRUCTIVE_SCHEMA_SQL|$DESTRUCTIVE_JSON_UPDATE_SQL" \
      >/dev/null
}

is_reviewed_expand_exception() {
  local filename="$1"
  local file="$2"
  local flattened_sql checksum index_name

  if [ "$SERVICE/$filename" = 'signal/26_pg18_optimizations.psql' ]; then
    # Migration 27 requires the gen_uuidv7() helper created by this
    # backward-compatible PG18 optimization transaction. Freeze the reviewed
    # bytes so its same-name index replacements cannot become a general escape.
    checksum="$(file_sha256 "$file")"
    [ "$checksum" = 'f4b5bcbc0aceb59c4edcad910819166c72b7742ef8e6eea930464fa2b1cbded0' ]
    return
  fi

  # Exact, byte-frozen exception for two same-name index replacements in one
  # historical Platform transaction. This is not a general DROP INDEX bypass.
  [ "$SERVICE/$filename" = 'platform/47_web_push_subscriptions.psql' ] || return 1
  checksum="$(file_sha256 "$file")"
  [ "$checksum" = '40b520d834c9412a21c81a2e46b4dfde46255417c9e652dfd4a0b66f9f1b96fa' ] \
    || return 1
  flattened_sql="$(LC_ALL=C tr '\r\n\t' '   ' < "$file")"
  [ "$(printf '%s\n' "$flattened_sql" | grep -Eio 'drop[[:space:]]+index' | wc -l | tr -d '[:space:]')" = 2 ] \
    || return 1
  for index_name in idx_web_push_subscriptions_user idx_web_push_subscriptions_delivery; do
    printf '%s\n' "$flattened_sql" \
      | grep -Ei "drop[[:space:]]+index[[:space:]]+if[[:space:]]+exists[[:space:]]+${index_name}[[:space:]]*;[[:space:]]*create[[:space:]]+index[[:space:]]+${index_name}([^[:alnum:]_]|$)" \
      >/dev/null || return 1
  done
}

encode_base64() {
  printf '%s' "$1" | base64 | tr -d '\n'
}

# These values arrive as exported environment variables. Copy them into
# unexported shell variables and remove the inherited names before invoking any
# child, then encode and discard the remaining plaintext immediately.
unset db_pass_plaintext platform_app_db_pass_plaintext
unset billing_app_db_pass_plaintext billing_superuser_db_pass_plaintext
unset signal_app_db_pass_plaintext signal_superuser_db_pass_plaintext
unset platform_verifier_db_pass_plaintext
unset db_pass_b64 platform_app_db_pass_b64 billing_app_db_pass_b64
unset billing_superuser_db_pass_b64 signal_app_db_pass_b64
unset signal_superuser_db_pass_b64 platform_verifier_db_pass_b64
db_pass_plaintext="$DB_PASS"
platform_app_db_pass_plaintext="${PLATFORM_APP_DB_PASS-}"
billing_app_db_pass_plaintext="${BILLING_APP_DB_PASS-}"
billing_superuser_db_pass_plaintext="${BILLING_SUPERUSER_DB_PASS-}"
signal_app_db_pass_plaintext="${SIGNAL_APP_DB_PASS-}"
signal_superuser_db_pass_plaintext="${SIGNAL_SUPERUSER_DB_PASS-}"
platform_verifier_db_pass_plaintext="${PLATFORM_VERIFIER_DB_PASS-}"
unset DB_PASS PLATFORM_APP_DB_PASS BILLING_APP_DB_PASS BILLING_SUPERUSER_DB_PASS
unset SIGNAL_APP_DB_PASS SIGNAL_SUPERUSER_DB_PASS PLATFORM_VERIFIER_DB_PASS
db_pass_b64="$(encode_base64 "$db_pass_plaintext")"
platform_app_db_pass_b64="$(encode_base64 "$platform_app_db_pass_plaintext")"
billing_app_db_pass_b64="$(encode_base64 "$billing_app_db_pass_plaintext")"
billing_superuser_db_pass_b64="$(encode_base64 "$billing_superuser_db_pass_plaintext")"
signal_app_db_pass_b64="$(encode_base64 "$signal_app_db_pass_plaintext")"
signal_superuser_db_pass_b64="$(encode_base64 "$signal_superuser_db_pass_plaintext")"
platform_verifier_db_pass_b64="$(encode_base64 "$platform_verifier_db_pass_plaintext")"
unset db_pass_plaintext platform_app_db_pass_plaintext billing_app_db_pass_plaintext
unset billing_superuser_db_pass_plaintext signal_app_db_pass_plaintext
unset signal_superuser_db_pass_plaintext platform_verifier_db_pass_plaintext

# Expanded by the child shell inside the PostgreSQL container.
# shellcheck disable=SC2016
PSQL_STDIN_WRAPPER='unset password_b64 PGPASSWORD; IFS= read -r password_b64; PGPASSWORD=$(printf "%s" "$password_b64" | base64 --decode); export PGPASSWORD; exec psql "$@"'
# The role passwords are also framed through stdin. psql imports the decoded
# environment values with \getenv, keeping every credential out of docker and
# psql argv.
# shellcheck disable=SC2016
PSQL_ROLE_STDIN_WRAPPER='decode() { printf "%s" "$1" | base64 --decode; }; unset password_b64 platform_b64 billing_b64 billing_super_b64 signal_b64 signal_super_b64 verifier_b64; unset PGPASSWORD APOLLO_PLATFORM_PASSWORD APOLLO_BILLING_PASSWORD APOLLO_BILLING_SUPER_PASSWORD APOLLO_SIGNAL_PASSWORD APOLLO_SIGNAL_SUPER_PASSWORD APOLLO_VERIFIER_PASSWORD; IFS= read -r password_b64; IFS= read -r platform_b64; IFS= read -r billing_b64; IFS= read -r billing_super_b64; IFS= read -r signal_b64; IFS= read -r signal_super_b64; IFS= read -r verifier_b64; PGPASSWORD=$(decode "$password_b64"); APOLLO_PLATFORM_PASSWORD=$(decode "$platform_b64"); APOLLO_BILLING_PASSWORD=$(decode "$billing_b64"); APOLLO_BILLING_SUPER_PASSWORD=$(decode "$billing_super_b64"); APOLLO_SIGNAL_PASSWORD=$(decode "$signal_b64"); APOLLO_SIGNAL_SUPER_PASSWORD=$(decode "$signal_super_b64"); APOLLO_VERIFIER_PASSWORD=$(decode "$verifier_b64"); export PGPASSWORD APOLLO_PLATFORM_PASSWORD APOLLO_BILLING_PASSWORD APOLLO_BILLING_SUPER_PASSWORD APOLLO_SIGNAL_PASSWORD APOLLO_SIGNAL_SUPER_PASSWORD APOLLO_VERIFIER_PASSWORD; exec psql "$@"'
LOCK_PID=""
LOCK_PIPE_DIR=""
LOCK_INPUT_OPEN=false
LOCK_OUTPUT_OPEN=false

docker_psql_command() {
  printf '%s\n' "$db_pass_b64" \
    | docker exec -i "$DB_CONTAINER" sh -c "$PSQL_STDIN_WRAPPER" sh "$@"
}

docker_psql_stdin() {
  {
    printf '%s\n' "$db_pass_b64"
    cat
  } | docker exec -i "$DB_CONTAINER" sh -c "$PSQL_STDIN_WRAPPER" sh "$@"
}

docker_psql_role_stdin() {
  {
    printf '%s\n' \
      "$db_pass_b64" \
      "$platform_app_db_pass_b64" \
      "$billing_app_db_pass_b64" \
      "$billing_superuser_db_pass_b64" \
      "$signal_app_db_pass_b64" \
      "$signal_superuser_db_pass_b64" \
      "$platform_verifier_db_pass_b64"
    printf '%s\n' \
      '\getenv platform_password APOLLO_PLATFORM_PASSWORD' \
      '\getenv billing_password APOLLO_BILLING_PASSWORD' \
      '\getenv billing_super_password APOLLO_BILLING_SUPER_PASSWORD' \
      '\getenv signal_password APOLLO_SIGNAL_PASSWORD' \
      '\getenv signal_super_password APOLLO_SIGNAL_SUPER_PASSWORD' \
      '\getenv verifier_password APOLLO_VERIFIER_PASSWORD'
    cat
  } | docker exec -i "$DB_CONTAINER" sh -c "$PSQL_ROLE_STDIN_WRAPPER" sh "$@"
}

wait_for_lock_session() {
  local remaining="$1"

  while [ "$remaining" -gt 0 ]; do
    if ! kill -0 "$LOCK_PID" 2>/dev/null; then
      wait "$LOCK_PID" 2>/dev/null || true
      return 0
    fi
    sleep 0.1
    remaining=$((remaining - 1))
  done
  return 1
}

stop_lock_session() {
  [ -n "$LOCK_PID" ] || return 0

  if wait_for_lock_session 20; then
    return 0
  fi

  kill -TERM "$LOCK_PID" 2>/dev/null || true
  if wait_for_lock_session 10; then
    return 0
  fi

  kill -KILL "$LOCK_PID" 2>/dev/null || true
  if ! wait_for_lock_session 10; then
    echo "WARNING: Could not reap the PostgreSQL migration lock session." >&2
  fi
}

release_migration_lock() {
  local exit_status=$?

  trap - EXIT INT TERM
  set +e
  if $LOCK_INPUT_OPEN && [ -n "$LOCK_PID" ]; then
    printf '%s\n' \
      "SELECT pg_advisory_unlock(hashtextextended(:'lock_name', 0));" \
      '\q' >&8 2>/dev/null
    exec 8>&-
    LOCK_INPUT_OPEN=false
  fi
  stop_lock_session
  if $LOCK_OUTPUT_OPEN; then
    exec 9<&-
    LOCK_OUTPUT_OPEN=false
  fi
  if [ -n "$LOCK_PIPE_DIR" ]; then
    rm -f "$LOCK_PIPE_DIR/input" "$LOCK_PIPE_DIR/output"
    rmdir "$LOCK_PIPE_DIR" 2>/dev/null
  fi
  exit "$exit_status"
}
trap release_migration_lock EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

echo "==> [$SERVICE] Waiting for the '$DB_NAME' migration lock..."
LOCK_PIPE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/apollo-migration-lock.XXXXXX")"
chmod 700 "$LOCK_PIPE_DIR"
mkfifo "$LOCK_PIPE_DIR/input" "$LOCK_PIPE_DIR/output"
docker exec -i "$DB_CONTAINER" sh -c "$PSQL_STDIN_WRAPPER" sh \
  -X -qAt -U "$DB_USER" -d postgres -v ON_ERROR_STOP=1 \
  -v "lock_name=$LOCK_NAME" \
  <"$LOCK_PIPE_DIR/input" >"$LOCK_PIPE_DIR/output" &
LOCK_PID=$!
# Fixed descriptors keep this runner compatible with the Bash 3 shipped by macOS.
exec 8>"$LOCK_PIPE_DIR/input"
LOCK_INPUT_OPEN=true
exec 9<"$LOCK_PIPE_DIR/output"
LOCK_OUTPUT_OPEN=true
printf '%s\n' \
  "$db_pass_b64" \
  "SET lock_timeout = '${MIGRATION_LOCK_TIMEOUT_SECONDS}s';" \
  "SELECT pg_advisory_lock(hashtextextended(:'lock_name', 0));" \
  "\echo $LOCK_MARKER" >&8

lock_acquired=false
lock_wait_remaining="$MIGRATION_LOCK_TIMEOUT_SECONDS"
while [ "$lock_wait_remaining" -gt 0 ]; do
  if IFS= read -r -t 1 lock_output <&9; then
    if [ "$lock_output" = "$LOCK_MARKER" ]; then
      lock_acquired=true
      break
    fi
    continue
  fi
  kill -0 "$LOCK_PID" 2>/dev/null || break
  lock_wait_remaining=$((lock_wait_remaining - 1))
done
if ! $lock_acquired; then
  if kill -0 "$LOCK_PID" 2>/dev/null && [ "$lock_wait_remaining" -eq 0 ]; then
    echo "ERROR: Timed out after $MIGRATION_LOCK_TIMEOUT_SECONDS seconds waiting for the PostgreSQL migration lock." >&2
  else
    echo "ERROR: PostgreSQL migration lock session ended unexpectedly." >&2
  fi
  exit 1
fi
echo "==> [$SERVICE] Migration lock acquired."

echo "==> [$SERVICE] Ensuring database '$DB_NAME' exists..."
docker_psql_command -U "$DB_USER" -d postgres \
  -tc "SELECT 1 FROM pg_database WHERE datname='$DB_NAME'" \
  | grep -q 1 \
  || docker_psql_command -U "$DB_USER" -d postgres \
       -c "CREATE DATABASE \"$DB_NAME\""

echo "==> [$SERVICE] Ensuring migration history table exists..."
docker_psql_command -U "$DB_USER" -d "$DB_NAME" -v ON_ERROR_STOP=1 -c "
    CREATE TABLE IF NOT EXISTS ${HISTORY_TABLE} (
      filename   TEXT PRIMARY KEY,
      checksum   TEXT NOT NULL,
      applied_at TIMESTAMPTZ NOT NULL DEFAULT now()
    );
    CREATE TABLE IF NOT EXISTS ${ATTEMPT_TABLE} (
      filename     TEXT PRIMARY KEY,
      checksum     TEXT NOT NULL,
      started_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
      completed_at TIMESTAMPTZ
    );"

shopt -s nullglob
files=("$MIGRATIONS_DIR"/*.psql)
shopt -u nullglob

if [ ${#files[@]} -eq 0 ]; then
  echo "==> [$SERVICE] No .psql files found — nothing to run."
  exit 0
fi

for file in "${files[@]}"; do
  filename=$(basename "$file")

  # This migration belongs to the Signal database, not the Platform database.
  if [ "$SERVICE" = "platform" ] && [ "$filename" = "39b_signal_grants.psql" ]; then
    continue
  fi

  if [[ ! "$filename" =~ ^[A-Za-z0-9._-]+\.psql$ ]]; then
    echo "ERROR: Unsafe migration filename '$filename'." >&2
    exit 1
  fi

  if ! configured_phase="$(
    awk -F '\t' -v service="$SERVICE" -v filename="$filename" '
      $1 == service && $2 == filename { count += 1; phase = $3 }
      END { if (count == 1) print phase; else exit 1 }
    ' "$MIGRATION_MANIFEST"
  )"; then
    echo "ERROR: Migration '$SERVICE/$filename' is missing from the reviewed phase manifest or is listed more than once." >&2
    exit 1
  fi
  case "$configured_phase" in
    expand|contract) ;;
    *)
      echo "ERROR: Migration '$SERVICE/$filename' has invalid reviewed phase '$configured_phase'." >&2
      exit 1
      ;;
  esac
  if [ "$configured_phase" = expand ] \
    && contains_destructive_sql "$file" \
    && ! is_reviewed_expand_exception "$filename" "$file"; then
    echo "ERROR: Destructive migration is classified as expand: $SERVICE/$filename" >&2
    exit 1
  fi
  if [ "$MIGRATION_PHASE" != all ] && [ "$MIGRATION_PHASE" != "$configured_phase" ]; then
    if [ "$configured_phase" = contract ]; then
      echo "    deferring contract migration until after the immutable application release: $filename"
    else
      echo "    skipping already-scheduled expand migration during the contract phase: $filename"
    fi
    continue
  fi

  if [ "$SERVICE" = platform ] \
    && [ "$filename" = "39_db_roles.psql" ] \
    && [ "$RECONCILE_DB_ROLES" = false ]; then
    echo "    deferring database-role credential reconciliation until after the infrastructure apply: $filename"
    continue
  fi

  checksum="$(file_sha256 "$file")"
  incomplete=$(docker_psql_command -U "$DB_USER" -d "$DB_NAME" -tAc \
    "SELECT checksum FROM ${ATTEMPT_TABLE}
       WHERE filename='$filename' AND completed_at IS NULL" \
    2>/dev/null | tr -d '[:space:]')
  if [ -n "$incomplete" ]; then
    echo "ERROR: Migration '$filename' has a started-but-incomplete prior attempt." >&2
    echo "Inspect the database and migration-attempt journal before resolving it; automatic replay is refused." >&2
    exit 1
  fi

  existing=$(docker_psql_command -U "$DB_USER" -d "$DB_NAME" -tAc \
    "SELECT checksum FROM ${HISTORY_TABLE} WHERE filename='$filename'" \
    2>/dev/null | tr -d '[:space:]')

  if [ -n "$existing" ]; then
    if [ "$existing" != "$checksum" ]; then
      echo "ERROR: Applied migration '$filename' has changed; add a new migration instead." >&2
      exit 1
    fi

    # The role migration is an idempotent credential reconciler. Every other
    # historical migration remains one-shot.
    if [ "$SERVICE" != "platform" ] || [ "$filename" != "39_db_roles.psql" ]; then
      echo "    skipping (already applied): $filename"
      continue
    fi
  fi

  is_role_migration=false
  if [ "$filename" = "39_db_roles.psql" ] && [ "$SERVICE" = "platform" ]; then
    is_role_migration=true
    for encoded_password in \
      "$platform_app_db_pass_b64" \
      "$billing_app_db_pass_b64" \
      "$billing_superuser_db_pass_b64" \
      "$signal_app_db_pass_b64" \
      "$signal_superuser_db_pass_b64" \
      "$platform_verifier_db_pass_b64"; do
      if [ -z "$encoded_password" ]; then
        echo "ERROR: All scoped database-role passwords are required for 39_db_roles.psql." >&2
        exit 1
      fi
    done
  fi

  docker_psql_command -U "$DB_USER" -d "$DB_NAME" -v ON_ERROR_STOP=1 -c "
      INSERT INTO ${ATTEMPT_TABLE} (filename, checksum, started_at, completed_at)
      VALUES ('$filename', '$checksum', now(), NULL)
      ON CONFLICT (filename) DO UPDATE
        SET checksum = EXCLUDED.checksum,
            started_at = EXCLUDED.started_at,
            completed_at = NULL"

  echo "    applying: $filename"
  if $is_role_migration; then
    docker_psql_role_stdin -U "$DB_USER" -d "$DB_NAME" -v ON_ERROR_STOP=1 < "$file"
  else
    docker_psql_stdin -U "$DB_USER" -d "$DB_NAME" -v ON_ERROR_STOP=1 < "$file"
  fi

  docker_psql_command -U "$DB_USER" -d "$DB_NAME" -v ON_ERROR_STOP=1 -c "
      WITH completed_attempt AS (
        UPDATE ${ATTEMPT_TABLE}
        SET completed_at = now()
        WHERE filename = '$filename'
          AND checksum = '$checksum'
          AND completed_at IS NULL
        RETURNING filename, checksum, completed_at
      ), recorded AS (
        INSERT INTO ${HISTORY_TABLE} (filename, checksum, applied_at)
        SELECT filename, checksum, completed_at
        FROM completed_attempt
        ON CONFLICT (filename) DO UPDATE
          SET checksum = EXCLUDED.checksum, applied_at = now()
        RETURNING 1
      )
      SELECT 1 / count(*) AS migration_completion_recorded
      FROM recorded"
done

echo "==> [$SERVICE] Migrations complete."
