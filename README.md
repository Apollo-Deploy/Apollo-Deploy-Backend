# Apollo Deploy — API Services

| Service | Port | Language | Database |
|---------|------|----------|----------|
| **Platform** | 3000 | TypeScript/Bun | `apollo_deploy_platform` |
| **Signal** | 3030 | Kotlin/Ktor | `apollo_deploy_signal` |
| **Billing** | 3040 | Kotlin/Ktor | `apollo_deploy_platform` |
| **Deployment** | 3050 *(planned)* | Kotlin/Ktor *(planned)* | `apollo_deploy_deployment` *(planned)* |

---

## Setup

The interactive setup keeps Terraform visible while handling configuration,
prerequisite checks, planning, and health verification:

```bash
bash infra/setup.sh
```

Choose local development or a production VPS. To inspect configuration without
applying anything:

```bash
bash infra/setup.sh local --plan-only
bash infra/setup.sh vps --plan-only
```

Day-to-day database and local API operations use the same entrypoint:

```bash
# Apply checksum-tracked migrations without restarting APIs
bash infra/setup.sh migrate local
bash infra/setup.sh migrate vps

# Detect changed API worktrees and refresh only their local containers
bash infra/setup.sh update
bash infra/setup.sh update --plan-only
```

`update` is intentionally local-only. In development mode it restarts the
selected bind-mounted containers so the JVM APIs rebuild from source. Outside
development mode it creates a targeted Terraform plan that rebuilds and
replaces only the changed API images and containers.

The wizard always shows the Terraform plan and requires confirmation before an
apply. Local secrets are generated in Terraform state. VPS service secrets are
generated into the ignored, mode-`600` `terraform.tfvars` file and then stored
in the encrypted remote state. On a successful setup, OAuth clients and HTTPS
are mandatory completion steps: local setup installs a trusted mkcert CA and
certificate, while VPS setup issues/reuses Let's Encrypt certificates and
verifies all three public API health endpoints plus backup health. A hosted
deployment without encrypted offsite upload requires explicit acceptance that
its backup copy shares the VPS failure domain.

The production `terraform.tfvars.example` values beginning with `CHANGEME` are
intentionally invalid. Use distinct PostgreSQL root, Redis, and scoped-role
passwords, and distinct session, cookie, internal-service, and Signal signing
secrets across trust boundaries. The wizard validates even reused VPS variables
before its first SSH or bootstrap action.

### Manual operation

Local Terraform remains directly callable for development and CI:

```bash
cd infra/terraform/local
terraform init
terraform plan
terraform apply
```

Local applies automatically reconcile migrations, grants, OAuth clients, and
container health. Hosted Terraform is different: production plans, applies,
imports, migrations, and OAuth operations must use `infra/setup.sh`; a bare
hosted-root command or direct VPS reconciler invocation is not supported.

### Configuration

The wizard creates the minimal local variables file. Optional integrations can
be added later using the example:

```bash
cd infra/terraform/local
cp terraform.tfvars.example terraform.tfvars
```

Disable Signal if you don't need it (no CodeArtifact token required):

```hcl
# terraform.tfvars
enable_signal = false
```

### Local dev (JVM hot-reload for signal/billing)

Run a service directly on the host while the rest of the stack stays in Docker:

```bash
cd apollo-signal-api && make dev
cd apollo-billing-api && make dev
cd apollo-platform-api && bun run dev
```

Override env values locally with `.env.local` (git-ignored, never overwritten).

### Useful commands

```bash
# Logs
docker logs -f apollo-platform
docker logs -f apollo-billing
docker logs -f apollo-signal

# Preview every local deletion, then run destroy only after reviewing it
cd infra/terraform/local && terraform plan -destroy

# Re-run pending migrations only
bash infra/setup.sh migrate local

# Re-run the full migrations, OAuth, restart, and health workflow
bash infra/scripts/reconcile-services.sh local
```

---

## Configuration

Each service reads from a single `.env` file. No dev/prod split — edit `.env` directly.

For PlanetScale (remote DB):
```env
DB_HOST=eu-west-3.pg.psdb.cloud
DB_USER=pscale_api_xxxxx.yyyyy
DB_PASSWORD=pscale_pw_xxxxxxxxx
DB_SSLMODE=require
```

For local Docker Postgres (platform compose provides it):
```env
DB_HOST=postgres
DB_USER=postgres
DB_PASSWORD=your_generated_password
DB_SSLMODE=disable
```

Per-developer overrides go in `.env.local` (loaded after `.env`, takes precedence).

---

## OAuth Clients

Services authenticate to each other via OAuth 2.0 `client_credentials`.
`infra/setup.sh` generates stable credentials in Terraform state and registers
the managed client definitions automatically after setup. No credentials need
to be copied into service `.env` files.

To repair only the database records without rotating credentials or restarting
the APIs:

```bash
bash infra/scripts/reconcile-services.sh local --oauth-only
```

The normal full reconciliation command also runs migrations, reconciles OAuth,
restarts the APIs, and waits for health checks.

---

## Database Migrations

Migrations live in each service's `scripts/migrations/` directory, but the
checksum journal, advisory lock, release-source verification, and reviewed
expand/contract ordering are enforced only by the canonical infrastructure
entrypoint:

```bash
# All services in dependency order
bash infra/setup.sh migrate local
bash infra/setup.sh migrate vps
```

The VPS command requires Cosign 3.0.6 or newer and verifies state-recorded image digests against keyless Sigstore
signatures, signed SLSA v1 provenance, immutable GHCR content, and config revision
metadata, then checks live image identity over strict SSH before database access.
A missing or mismatched build identity—or a live container using another image
identity—fails closed and requires a normal verified VPS deployment first.

The service-level `init.sh` installers are bootstrap conveniences for isolated
local service development; they are not production deploy paths. Do not pass a
production database URL or password on a `psql` command line. Hosted changes
must go through `bash infra/setup.sh vps`, which runs reviewed expand migrations
before the exact immutable-image plan is applied. Contract migrations are not
executable from this repository and require a separately governed DBA/release
process.

---

## SSL / TLS

### Local

Install `mkcert` once (`brew install mkcert` on macOS). The setup wizard then
installs the local CA, creates or refreshes an ignored certificate for the API
and local website-development hosts, restarts nginx, and verifies Platform,
Billing, and Signal over HTTPS. These website proxies are local-only;
production website domains remain owned by Vercel.

```bash
bash infra/setup.sh local
```

### Production

VPS setup automatically issues or reuses one Let's Encrypt certificate for all
three API domains, installs the nginx routes, and checks the public HTTPS health
endpoints. It then fails closed unless Certbot renewal and near-expiry health is
healthy. Certbot renews it automatically every 12 hours.

The lower-level recovery command remains available:

```bash
bash infra/scripts/setup-vps-tls.sh deploy@your-vps your-domain.example ops@your-domain.example
```

---

## Architecture

```
       nginx :80/:443
         │
    ┌────┼─────────────────┐
    │    │                  │
 Platform  Signal       Billing
  :3000    :3030         :3040
    │        │              │
    └────┬───┴──────────────┘
         │
   PostgreSQL + Redis
```

All services share the `platform_default` Docker network. Platform owns Postgres, Redis, PgBouncer, nginx, and certbot. Signal and billing join as external services.

---

## CodeArtifact Token (Signal builds)

Signal currently resolves Billing SDK `1.6.0` and its private Tesseract manifest dependency from AWS CodeArtifact. Move the Billing dependency to Maven Central after `1.6.0` (or a newer compatible version) is publicly released. CodeArtifact tokens expire every 12h.

```bash
cd apollo-signal-api
make codeartifact-token   # refreshes and writes to .env + ~/.gradle
```

Must be set before `docker compose build`.

---

## Troubleshooting

| Error | Fix |
|-------|-----|
| "User parameter must include branch" | PlanetScale requires `pscale_api_*` username format |
| "SSL/TLS required" | Set `DB_SSLMODE=require` / `DB_SSL_ENABLED=true` |
| "missing client" | Run `bun run oauth:register-clients` in platform |
| Cookie not set | `AUTH_COOKIE_DOMAIN` must match your access domain |
| Signal build 401 | Refresh CodeArtifact token: `make codeartifact-token` |
| Redis WRONGPASS | Recreate: `docker compose up -d --force-recreate redis` |
