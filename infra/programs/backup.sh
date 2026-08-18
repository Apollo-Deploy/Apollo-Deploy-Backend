#!/bin/sh
set -eu
umask 077

prune_backups() {
  set -- /backups/postgres-*.sql
  [ -e "$1" ] || return 0
  while [ "$#" -gt "$BACKUP_RETENTION_COUNT" ]; do
    rm -f -- "$1"
    shift
  done
}

backup_once() {
  timestamp="$(date -u '+%Y%m%dT%H%M%SZ')"
  temporary="/backups/.postgres-$timestamp-$$.sql.tmp"
  final="/backups/postgres-$timestamp.sql"
  trap 'rm -f -- "$temporary"' EXIT INT TERM

  # Restores target a clean replacement cluster. A --clean dump tries to drop
  # the bootstrap postgres role while connected as that role and cannot restore.
  pg_dumpall --no-password --quote-all-identifiers --file="$temporary"
  test -s "$temporary"
  chmod 0600 "$temporary"
  sync "$temporary"
  mv "$temporary" "$final"
  trap - EXIT INT TERM
  prune_backups
  date -u +%s >/backups/.last-success.tmp
  chmod 0600 /backups/.last-success.tmp
  mv /backups/.last-success.tmp /backups/.last-success
  sync /backups/.last-success
}

while :; do
  if backup_once; then
    sleep "$BACKUP_INTERVAL_SECONDS"
  else
    echo 'PostgreSQL backup failed; retrying' >&2
    sleep "$BACKUP_RETRY_INTERVAL_SECONDS"
  fi
done
