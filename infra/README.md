# Apollo infrastructure

Apollo uses one operational entrypoint:

```bash
./infra/apollo --help
```

Docker Compose owns the single-host runtime: PostgreSQL, PgBouncer, Redis,
Platform, Signal, Billing, Nginx, Certbot and backups. Terraform owns only AWS
and Cloudflare resources. The accepted boundary and alternatives are recorded
in [ADR 001](docs/adr/001-compose-runtime.md).

## Local development

On a fresh machine:

```bash
./infra/apollo local setup
./infra/apollo local status
./infra/apollo local logs --follow
```

The first setup creates ignored mode-0600 files from
`config/local.env.example` and `config/secrets.env.example`. Review
`config/local.env` and add integration credentials to
`config/local.secrets.env`. Derived per-service files live under the ignored
`infra/.runtime/` directory.

The repository's local Terraform handoff has completed and its transition root
has been removed. Local commands use Compose directly and never initialize
Terraform.

Useful commands:

```bash
./infra/apollo local up
./infra/apollo local down
./infra/apollo local migrate expand
./infra/apollo local migrate contract
```

`down` stops containers. The CLI never passes Compose's volume-removal flag.

## Production VPS

1. Copy `config/vps.env.example` to the ignored `config/vps.env`, set its mode
   to 0600, and review every host, domain, AWS, Cloudflare and backend value.
2. Copy `config/secrets.env.example` to the ignored
   `config/vps.secrets.env`, set its mode to 0600, and populate credentials.
3. Put the exact VPS host key in the configured dedicated `known_hosts` file.
4. Select an immutable digest-qualified entry from
   `releases/approved-releases.json`.

Setup renders Terraform's Signal outputs once into the ignored mode-0600
`config/vps.aws.env`. Normal deploy reads that protected cache and does not
initialize Terraform or require AWS credentials; rerun setup after an explicit
external-infrastructure change to refresh it.

For a fresh VPS:

```bash
./infra/apollo vps plan
./infra/apollo vps setup --release RELEASE_ID
```

For the one-time transition from Terraform-managed Docker:

```bash
./infra/apollo vps adopt --release RELEASE_ID
```

Follow the reviewable preparation and state checks in
[migration-from-terraform.md](docs/migration-from-terraform.md). Adoption is
separate from normal deployment and never runs implicitly.

Normal releases use:

```bash
./infra/apollo vps deploy --release RELEASE_ID
./infra/apollo vps status
./infra/apollo vps logs --follow
```

A production mutation requires the exact clean current remote `origin/main`, a
strict SSH host-key match, the configured native `/etc/machine-id`, the
expected AWS account, and a catalog release whose service images pass the
repository's Cosign provenance verifier. The VPS stages configuration, takes
`flock`, pulls images, runs expand migrations, converges Compose, waits for all
health checks, restores the newest PostgreSQL dump into an isolated disposable
database, issues or verifies TLS, and checks the three public HTTPS routes and
their service identities. Only then does it atomically promote
`current-release`. A failed gate does not promote the candidate and attempts to
restore the previous staged Compose release.

Explicit operational commands:

```bash
./infra/apollo vps migrate contract
./infra/apollo vps backup
./infra/apollo vps restore-check
```

Contract migrations are never part of normal deploy. Production backup storage
is an external named volume. Set `ENABLE_OFFSITE_BACKUP=true` and populate the
R2/Restic keys for off-host retention; a same-host backup alone does not cover
host loss.

The destructive recovery sequence is intentionally not a routine CLI command;
follow [restore-and-recovery.md](docs/restore-and-recovery.md). The measured
before/after reduction is in
[complexity-comparison.md](docs/complexity-comparison.md).

## Configuration ownership

| Data | Source of truth | Persisted in Terraform state? |
| --- | --- | --- |
| AWS and Cloudflare resources | `config/vps.env` plus Terraform | Yes, non-runtime data |
| AWS IAM access key created by Terraform | Terraform sensitive output | Yes; provider constraint |
| Application/database/integration secrets | ignored `*.secrets.env` | No new state values |
| Derived Signal AWS runtime values | ignored `vps.aws.env` | IAM key also remains in Terraform state |
| Container topology and health | `compose/*.yaml` | No |
| Production application versions | approved release catalog | No |
| Database schema history | PostgreSQL migration tables | No |

Existing retained S3 state versions from before the handoff can still contain
old Docker environment secrets. Rotate those credentials after adoption, then
apply the organization's approved version-retention cleanup; do not delete
state history before rollback and audit requirements are satisfied.

## Validation

Run the same secret-free gate used on pull requests:

```bash
bash infra/scripts/check-infra.sh
```

It validates Terraform formatting and both roots, both Compose projections,
shell syntax/style/static analysis, JSON schemas, tracked-secret policy and the
infrastructure regression tests. Authenticated registry provenance checks run
only on a protected push, so pull-request code never receives the private
package token.
