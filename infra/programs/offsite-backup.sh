#!/bin/sh
set -eu
umask 077

restic snapshots >/dev/null 2>&1 || restic init
while :; do
  restic backup /backups --tag apollo-postgres
  restic forget --keep-last "$BACKUP_RETENTION_COUNT" --prune
  date -u +%s >/tmp/last-offsite-success
  sleep "$OFFSITE_INTERVAL_SECONDS"
done
