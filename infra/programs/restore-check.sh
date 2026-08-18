#!/usr/bin/env bash
set -euo pipefail

PROGRAM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APOLLO_ROOT="$(cd "$PROGRAM_DIR/.." && pwd)"
# shellcheck source=../lib/common.sh
source "$APOLLO_ROOT/lib/common.sh"

require_command docker
require_command openssl

secret_file="${APOLLO_SECRET_FILE:-$APOLLO_ROOT/config/secrets.env}"
postgres_image="${POSTGRES_IMAGE:?POSTGRES_IMAGE is required}"
require_protected_file "$secret_file" 'Apollo secrets'

suffix="$(openssl rand -hex 6)"
container="apollo-restore-check-$suffix"
volume="apollo-restore-check-$suffix"
env_file="$(mktemp "${TMPDIR:-/tmp}/apollo-restore-env.XXXXXX")"
[[ "$container" =~ ^apollo-restore-check-[0-9a-f]{12}$ ]] || die 'Unsafe restore-check identity.'

cleanup() {
  local status=$?
  trap - EXIT INT TERM
  docker container rm --force "$container" >/dev/null 2>&1 || true
  docker volume rm "$volume" >/dev/null 2>&1 || true
  rm -f -- "$env_file"
  exit "$status"
}
trap cleanup EXIT INT TERM

chmod 600 "$env_file"
{
  # Use an out-of-band bootstrap administrator so the dump can recreate the
  # production `postgres` role exactly as captured.
  printf 'POSTGRES_USER=apollo_restore_admin\nPOSTGRES_DB=postgres\n'
  printf 'POSTGRES_PASSWORD=%s\n' "$(env_value "$secret_file" POSTGRES_PASSWORD)"
} >"$env_file"

latest_backup="$(docker run --rm -v apollo-postgres-backups:/backups:ro "$postgres_image" \
  sh -c 'latest=""; for path in /backups/postgres-*.sql; do test -e "$path" || exit 1; latest="$path"; done; printf "%s\n" "$latest"')" \
  || die 'No PostgreSQL backup is available for restore verification.'

docker volume create "$volume" >/dev/null
docker run -d --name "$container" --env-file "$env_file" \
  -v "$volume:/var/lib/postgresql" "$postgres_image" >/dev/null

for _ in {1..60}; do
  docker exec "$container" pg_isready -U apollo_restore_admin -d postgres >/dev/null 2>&1 && break
  sleep 1
done
docker exec "$container" pg_isready -U apollo_restore_admin -d postgres >/dev/null \
  || die 'Disposable PostgreSQL did not become ready.'

docker run --rm -v apollo-postgres-backups:/backups:ro "$postgres_image" \
  sh -c "cat '$latest_backup'" \
  | docker exec -i "$container" sh -c \
    'PGPASSWORD="$POSTGRES_PASSWORD" psql -X --quiet -v ON_ERROR_STOP=1 -U apollo_restore_admin -d postgres' \
    >/dev/null

docker exec "$container" sh -c \
  'PGPASSWORD="$POSTGRES_PASSWORD" psql -X -v ON_ERROR_STOP=1 -U apollo_restore_admin -d postgres -tAc "
    SELECT count(*) = 2 FROM pg_database
    WHERE datname IN ('"'"'apollo_deploy_platform'"'"', '"'"'apollo_deploy_signal'"'"');
  "' | grep -qx t
docker exec "$container" sh -c \
  'PGPASSWORD="$POSTGRES_PASSWORD" psql -X -v ON_ERROR_STOP=1 -U apollo_restore_admin -d apollo_deploy_platform -tAc "SELECT count(*) >= 3 FROM \"oauthClient\""' \
  | grep -qx t

date -u +%s | docker run --rm -i -v apollo-postgres-backups:/backups "$postgres_image" \
  sh -c 'umask 077; cat > /backups/.last-restore-check.tmp; mv /backups/.last-restore-check.tmp /backups/.last-restore-check'
info "Backup restore verification passed for $latest_backup."
