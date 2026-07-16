#!/usr/bin/env bash
# =============================================================================
# run-migrations.sh — idempotent database migrations via docker exec
#
# Environment variables:
#   DB_CONTAINER   (required) — postgres container name
#   DB_PASS        (required) — postgres superuser password
#   DB_USER        (default: postgres)
#   DB_NAME        (required) — database to migrate
#   MIGRATIONS_DIR (required) — host path containing *.psql files
#   SERVICE        (required) — service name: platform | signal | billing
#
# For service=platform and the 39_db_roles.psql file, also set:
#   PLATFORM_APP_DB_PASS
#   BILLING_APP_DB_PASS
#   BILLING_SUPERUSER_DB_PASS
#   SIGNAL_APP_DB_PASS
#   SIGNAL_SUPERUSER_DB_PASS
#   PLATFORM_VERIFIER_DB_PASS
# =============================================================================
set -euo pipefail

DB_CONTAINER="${DB_CONTAINER:?ERROR: DB_CONTAINER is required}"
DB_PASS="${DB_PASS:?ERROR: DB_PASS is required}"
DB_USER="${DB_USER:-postgres}"
DB_NAME="${DB_NAME:?ERROR: DB_NAME is required}"
MIGRATIONS_DIR="${MIGRATIONS_DIR:?ERROR: MIGRATIONS_DIR is required}"
SERVICE="${SERVICE:?ERROR: SERVICE is required (platform|signal|billing)}"

HISTORY_TABLE="_${SERVICE}_migration_history"

echo "==> [$SERVICE] Ensuring database '$DB_NAME' exists..."
docker exec -e PGPASSWORD="$DB_PASS" "$DB_CONTAINER" \
  psql -U "$DB_USER" -d postgres \
  -tc "SELECT 1 FROM pg_database WHERE datname='$DB_NAME'" \
  | grep -q 1 \
  || docker exec -e PGPASSWORD="$DB_PASS" "$DB_CONTAINER" \
       psql -U "$DB_USER" -d postgres \
       -c "CREATE DATABASE \"$DB_NAME\""

echo "==> [$SERVICE] Ensuring migration history table exists..."
docker exec -e PGPASSWORD="$DB_PASS" "$DB_CONTAINER" \
  psql -U "$DB_USER" -d "$DB_NAME" -v ON_ERROR_STOP=1 -c "
    CREATE TABLE IF NOT EXISTS ${HISTORY_TABLE} (
      filename   TEXT PRIMARY KEY,
      checksum   TEXT NOT NULL,
      applied_at TIMESTAMPTZ NOT NULL DEFAULT now()
    );"

echo "==> [$SERVICE] Running migrations from $MIGRATIONS_DIR..."

shopt -s nullglob
FILES=("$MIGRATIONS_DIR"/*.psql)
shopt -u nullglob

if [ ${#FILES[@]} -eq 0 ]; then
  echo "==> [$SERVICE] No .psql files found — nothing to run."
  exit 0
fi

for f in $(ls "$MIGRATIONS_DIR"/*.psql | sort); do
  filename=$(basename "$f")

  # Compute checksum (portable: prefer shasum, fall back to sha256sum)
  checksum=$(shasum -a 256 "$f" 2>/dev/null | cut -d' ' -f1 \
             || sha256sum "$f" | cut -d' ' -f1)

  # Check if already applied with same checksum
  existing=$(docker exec -e PGPASSWORD="$DB_PASS" "$DB_CONTAINER" \
    psql -U "$DB_USER" -d "$DB_NAME" -tAc \
    "SELECT checksum FROM ${HISTORY_TABLE} WHERE filename='$filename'" \
    2>/dev/null | tr -d '[:space:]')

  if [ -n "$existing" ] && [ "$existing" = "$checksum" ]; then
    echo "    skipping (already applied): $filename"
    continue
  fi

  echo "    applying: $filename"

  # Special handling for the DB roles migration — needs psql variables for passwords
  if [ "$filename" = "39_db_roles.psql" ] && [ "$SERVICE" = "platform" ]; then
    {
      printf "\\\\set platform_password '%s'\n"      "${PLATFORM_APP_DB_PASS:?}"
      printf "\\\\set billing_password '%s'\n"       "${BILLING_APP_DB_PASS:?}"
      printf "\\\\set billing_super_password '%s'\n" "${BILLING_SUPERUSER_DB_PASS:?}"
      printf "\\\\set signal_password '%s'\n"        "${SIGNAL_APP_DB_PASS:?}"
      printf "\\\\set signal_super_password '%s'\n"  "${SIGNAL_SUPERUSER_DB_PASS:?}"
      printf "\\\\set verifier_password '%s'\n"      "${PLATFORM_VERIFIER_DB_PASS:?}"
      cat "$f"
    } | docker exec -i -e PGPASSWORD="$DB_PASS" "$DB_CONTAINER" \
        psql -U "$DB_USER" -d "$DB_NAME" -v ON_ERROR_STOP=1
  else
    docker exec -i -e PGPASSWORD="$DB_PASS" "$DB_CONTAINER" \
      psql -U "$DB_USER" -d "$DB_NAME" -v ON_ERROR_STOP=1 < "$f"
  fi

  # Record successful application
  docker exec -e PGPASSWORD="$DB_PASS" "$DB_CONTAINER" \
    psql -U "$DB_USER" -d "$DB_NAME" -c "
      INSERT INTO ${HISTORY_TABLE} (filename, checksum)
      VALUES ('$filename', '$checksum')
      ON CONFLICT (filename) DO UPDATE
        SET checksum = EXCLUDED.checksum, applied_at = now()"

done

echo "==> [$SERVICE] Migrations complete."
