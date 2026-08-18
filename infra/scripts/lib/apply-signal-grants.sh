#!/usr/bin/env bash
# Apply the Signal-only cross-database grants after the Signal database exists.
set -euo pipefail

DB_CONTAINER="${DB_CONTAINER:?ERROR: DB_CONTAINER is required}"
DB_PASS="${DB_PASS:?ERROR: DB_PASS is required}"
DB_USER="${DB_USER:-postgres}"
PLATFORM_DB_NAME="${PLATFORM_DB_NAME:?ERROR: PLATFORM_DB_NAME is required}"
SIGNAL_DB_NAME="${SIGNAL_DB_NAME:?ERROR: SIGNAL_DB_NAME is required}"
GRANTS_FILE="${GRANTS_FILE:?ERROR: GRANTS_FILE is required}"
unset db_pass_plaintext DB_PASS_B64
db_pass_plaintext="$DB_PASS"
unset DB_PASS
DB_PASS_B64="$(printf '%s' "$db_pass_plaintext" | base64 | tr -d '\n')"
unset db_pass_plaintext
# Expanded by the child shell inside the PostgreSQL container.
# shellcheck disable=SC2016
PSQL_STDIN_WRAPPER='IFS= read -r password_b64; PGPASSWORD=$(printf "%s" "$password_b64" | base64 --decode); export PGPASSWORD; exec psql "$@"'

docker_psql_stdin() {
  {
    printf '%s\n' "$DB_PASS_B64"
    cat
  } | docker exec -i "$DB_CONTAINER" sh -c "$PSQL_STDIN_WRAPPER" sh "$@"
}

for identifier in "$DB_USER" "$PLATFORM_DB_NAME" "$SIGNAL_DB_NAME"; do
  if [[ ! "$identifier" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
    echo "ERROR: Unsafe PostgreSQL identifier '$identifier'." >&2
    exit 1
  fi
done

if [ ! -f "$GRANTS_FILE" ]; then
  echo "ERROR: Signal grants file does not exist: $GRANTS_FILE" >&2
  exit 1
fi

echo "==> [signal grants] Revoking accidental Platform database access..."
docker_psql_stdin -U "$DB_USER" -d "$PLATFORM_DB_NAME" -v ON_ERROR_STOP=1 \
  -v "platform_db_name=$PLATFORM_DB_NAME" <<'SQL'
REVOKE ALL PRIVILEGES ON ALL TABLES IN SCHEMA public FROM signal_app;
REVOKE ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public FROM signal_app;
REVOKE ALL PRIVILEGES ON ALL FUNCTIONS IN SCHEMA public FROM signal_app;
REVOKE ALL PRIVILEGES ON SCHEMA public FROM signal_app;
SELECT format('REVOKE ALL PRIVILEGES ON DATABASE %I FROM signal_app', :'platform_db_name') \gexec

REVOKE ALL PRIVILEGES ON ALL TABLES IN SCHEMA public FROM signal_superuser;
REVOKE ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public FROM signal_superuser;
REVOKE ALL PRIVILEGES ON ALL FUNCTIONS IN SCHEMA public FROM signal_superuser;
REVOKE ALL PRIVILEGES ON SCHEMA public FROM signal_superuser;
SELECT format('REVOKE ALL PRIVILEGES ON DATABASE %I FROM signal_superuser', :'platform_db_name') \gexec

ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE ALL PRIVILEGES ON TABLES FROM signal_app;
ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE ALL PRIVILEGES ON SEQUENCES FROM signal_app;
ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE ALL PRIVILEGES ON FUNCTIONS FROM signal_app;

DELETE FROM _platform_migration_history WHERE filename = '39b_signal_grants.psql';
SQL

echo "==> [signal grants] Reconciling Signal database access..."
docker_psql_stdin -U "$DB_USER" -d postgres -v ON_ERROR_STOP=1 \
  -v "signal_db_name=$SIGNAL_DB_NAME" <<'SQL'
SELECT format(
  'GRANT CONNECT ON DATABASE %I TO signal_app, signal_superuser, platform_verifier, billing_superuser',
  :'signal_db_name'
) \gexec
SQL

echo "==> [signal grants] Applying grants to $SIGNAL_DB_NAME..."
docker_psql_stdin -U "$DB_USER" -d "$SIGNAL_DB_NAME" -v ON_ERROR_STOP=1 \
  <"$GRANTS_FILE"
