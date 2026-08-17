#!/usr/bin/env bash
# Run SQL from stdin without placing the PostgreSQL password in a process argv.
set -euo pipefail

DB_CONTAINER="${DB_CONTAINER:?ERROR: DB_CONTAINER is required}"
DB_PASS_B64="${DB_PASS_B64:?ERROR: DB_PASS_B64 is required}"
DB_USER="${DB_USER:?ERROR: DB_USER is required}"
DB_NAME="${DB_NAME:?ERROR: DB_NAME is required}"
unset db_pass_b64
db_pass_b64="$DB_PASS_B64"
unset DB_PASS_B64

if [[ ! "$DB_CONTAINER" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] \
  || [[ ! "$DB_USER" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] \
  || [[ ! "$DB_NAME" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] \
  || [[ ! "$db_pass_b64" =~ ^[A-Za-z0-9+/]*={0,2}$ ]]; then
  echo "ERROR: Unsafe PostgreSQL stdin-runner configuration." >&2
  exit 1
fi

{
  printf '%s\n' "$db_pass_b64"
  cat
} | docker exec -i "$DB_CONTAINER" sh -c '
  IFS= read -r password_b64
  PGPASSWORD=$(printf "%s" "$password_b64" | base64 --decode)
  export PGPASSWORD
  exec psql -U "$1" -d "$2" -v ON_ERROR_STOP=1
' sh "$DB_USER" "$DB_NAME"
