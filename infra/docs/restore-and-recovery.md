# PostgreSQL restore and host recovery

Apollo separates a restore drill from a destructive production restore.
`./infra/apollo vps restore-check` reads the newest SQL backup, restores it to
a randomly named disposable PostgreSQL container and volume, verifies both
databases plus the three OAuth client rows, records the successful check, and
deletes the disposable resources. It never connects to the live database.

Every backup-enabled deployment runs the same drill before promoting the
release. This proves the latest dump is usable; it does not protect against
loss of the host holding that dump. Production should enable the Restic/R2
offsite profile and monitor its health.

## Restore after data-volume loss

Treat this as an exceptional production operation. Do not run setup or deploy
after discovering a missing or corrupt `apollo-postgres-data` volume: both
commands intentionally fail closed on an established host with missing durable
storage.

1. Stop application traffic and record the configured VPS machine ID, current
   release, image digests, volume inventory and incident time.
2. Recover the newest appropriate SQL dump from the external
   `apollo-postgres-backups` volume or the encrypted Restic repository. Keep
   the source backup immutable.
3. Run the isolated restore check against that dump. If it fails, preserve its
   logs and select an earlier verified dump.
4. On a clean replacement volume, initialize PostgreSQL 18.4 with a temporary
   out-of-band superuser named `apollo_restore_admin`; do not use `postgres`,
   because the dump recreates the captured production `postgres` role.
5. Feed the dump to `psql -X --set ON_ERROR_STOP=1` as that temporary
   superuser. Validate both databases, expected schema objects, OAuth clients,
   migration histories and application-specific row counts.
6. Keep the original volume detached. Only after validation, make the restored
   volume the explicit `apollo-postgres-data` volume on the verified target.
7. Start PostgreSQL alone, then PgBouncer and Redis, run `migrate expand`, and
   finally converge the last known-good immutable release. Verify every health
   endpoint and run another isolated restore drill before reopening traffic.

Volume creation, attachment and replacement are deliberately manual during an
incident. The automation has no `reset`, `delete-volume`, or in-place restore
command that could overwrite production data during routine operation.

## Host replacement

Build the replacement host separately. Restore PostgreSQL, Redis data if
required, TLS material or freshly issued certificates, and backup history
before changing traffic. Pin its SSH host key in the dedicated `known_hosts`
file and obtain `/etc/machine-id` through an independent channel. Updating
`VPS_MACHINE_ID`, the host key, Cloudflare origin or AWS account is an explicit
reviewed configuration change; normal deployment never adopts a new identity.

Keep the old host stopped but recoverable until application checks, external
AWS/Cloudflare plans, offsite backup, and restore verification all pass on the
replacement.
