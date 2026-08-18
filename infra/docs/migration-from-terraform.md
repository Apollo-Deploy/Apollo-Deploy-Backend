# Migration from Terraform-managed Docker

This is a one-time state and runtime ownership handoff. It is intentionally not
part of normal setup or deploy.

## Preconditions

- Record the current container health, image digests, Docker network and named
  volumes.
- Take a PostgreSQL backup and successfully restore it in isolation.
- Verify the production S3 backend is versioned, encrypted and recoverable.
- Prepare ignored mode-0600 `config/vps.env` and `config/vps.secrets.env` from
  the examples. Translate existing values without printing them to logs.
- Put only the expected VPS host key in the dedicated `known_hosts` file and
  confirm the host's `/etc/machine-id` out of band.
- Choose an approved release matching the currently intended service commits.
- Ensure the local checkout is the clean exact current remote `origin/main`.

Do not destroy or rename these resources:

```text
apollo-postgres-data
apollo-redis-data
apollo-letsencrypt-certs
apollo-certbot-webroot
apollo-postgres-backups
apollo
```

## Local handoff complete

The local state-only handoff completed with zero remaining Terraform resources,
and the transition root and legacy state backups have been removed. Every live
local container is now owned by Compose project `apollo`. New local setups use
`./infra/apollo local setup` directly.

## VPS handoff

Run `./infra/apollo vps adopt --release RELEASE_ID`. The command:

1. verifies the clean reviewed infrastructure revision, AWS account, SSH host
   key, native machine ID and approved release provenance;
2. displays an external-infrastructure Terraform saved plan;
3. applies `removed { destroy = false }` for the legacy Docker module;
4. copies the live Nginx configuration before container replacement;
5. fails if any established durable volume or network is missing;
6. stages protected runtime files, removes only named containers under
   `flock`, and converges Compose;
7. runs expand migrations, internal health gates and an isolated backup restore
   before promotion, then gates completion on the three public HTTPS routes.

Successful deployments retain only the current and immediately previous staged
release. Staging and deployment use the same VPS lock file, and deployment
rechecks the content identity after acquiring its lock, so concurrent operators
cannot replace a release between verification and use.

The saved plan must show no Docker destruction. Stop if any durable resource is
deleted or replaced. A production state apply is an operator-approved action;
CI never applies it.

## Rollback and recovery

The Terraform handoff is state-only and does not remove Docker objects. Before
container replacement, rollback is simply to stop and investigate. After
replacement, rerun the same adoption/deploy command: Compose convergence and
database migrations are retryable, and the prior staged release remains
available. A failed internal health or restore gate does not promote the
candidate. A failed public HTTPS gate restores the prior Compose release and
`/opt/apollo/current-release` marker.

Never restore an empty replacement volume over an established installation.
If a durable volume is missing, stop; restore it from the verified backup or
snapshot before running Compose again. For an intentional VPS replacement,
update the dedicated host key and machine ID only after independently verifying
the new host and restoring all durable data.

Keep the VPS Docker provider lock entry and `removed` block until production
state has applied the handoff and contains no Docker addresses. Remove them in a
later reviewed cleanup after production adoption evidence is captured.

## Secret cleanup

The new configuration does not send application, database, OAuth, Polar, R2 or
Restic secrets into Terraform. Historical state versions may still contain
their former values. After the runtime is healthy:

1. rotate every formerly state-backed credential;
2. verify services use the rotated values;
3. retain or expire old state versions according to the approved audit and
   rollback policy;
4. remove legacy ignored `terraform.tfvars` only after confirming no remaining
   value is needed for external infrastructure.
