# Apollo Deploy — API Services

| Service | Port | Language | Database |
|---------|------|----------|----------|
| **Platform** | 3000 | TypeScript/Bun | `apollo_deploy_platform` |
| **Signal** | 3030 | Kotlin/Ktor | `apollo_deploy_signal` |
| **Billing** | 3040 | Kotlin/Ktor | `apollo_deploy_platform` |

---

## Setup

The full local stack is managed by Terraform. One command starts everything:
Postgres, PgBouncer, Redis, Platform API, nginx, Billing, and Signal (optional).

### Prerequisites

```bash
# Required: pulls @apollo-deploy/* npm packages
export NPM_TOKEN=npm_...

# Required only if enable_signal=true
export CODEARTIFACT_AUTH_TOKEN=...   # cd apollo-signal-api && make codeartifact-token
```

### First time

```bash
cd infra/terraform/environments/local
terraform init
terraform apply -auto-approve
```

Secrets are auto-generated and stored in Terraform state. Migrations and OAuth
client registration run automatically as part of `apply`.

### Every time after

```bash
cd infra/terraform/environments/local
terraform apply -auto-approve
```

Terraform is idempotent — only changed resources are updated.

### Configuration

Copy the example vars file and uncomment what you need:

```bash
cd infra/terraform/environments/local
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

# Stop everything
cd infra/terraform/environments/local && terraform destroy -auto-approve

# Re-run migrations only (bump the trigger value)
terraform apply -auto-approve -var='migration_trigger=2026-07-16'
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

Services authenticate to each other via OAuth 2.0 `client_credentials`. Register once after platform migrations:

```bash
cd apollo-platform-api
bun run oauth:register-clients
```

Register two clients (signal + billing), then put the output credentials in each service's `.env`:

| Service | Env vars to set |
|---------|----------------|
| Signal | `PLATFORM_CLIENT_ID`, `PLATFORM_CLIENT_SECRET` |
| Billing | `PLATFORM_CLIENT_ID`, `PLATFORM_CLIENT_SECRET` |
| Platform | `OAUTH_TRUSTED_CLIENT_IDS`, `OAUTH_SERVICE_CLIENT_IDS` |

Or pass `--clients <file>` for headless registration from a JSON definition.

---

## Database Migrations

Migrations live in each service's `scripts/migrations/` directory.

```bash
# Platform
cd apollo-platform-api && ./init.sh --skip-oauth

# Signal
cd apollo-signal-api && ./init.sh --skip-token

# Billing
cd apollo-billing-api && ./init.sh
```

Or run all three in dependency order against a remote DB:

```bash
cd apollo-platform-api
psql "$DATABASE_URL" -f scripts/migrations/*.psql
```

---

## SSL / TLS

### Local (mkcert)

```bash
brew install mkcert nss && mkcert -install
cd apollo-platform-api/scripts/nginx/certs
mkcert "*.apollodeploy.local" "apollodeploy.local" "localhost"
```

### Production (Let's Encrypt)

```bash
cd apollo-platform-api
scripts/install/setup-ssl.sh --service platform --domain api.platform.yourdomain.com --email admin@yourdomain.com
scripts/install/setup-ssl.sh --service signal   --domain api.signal.yourdomain.com
scripts/install/setup-ssl.sh --service billing  --domain api.billing.yourdomain.com
```

Certbot renews automatically every 12h.

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

Signal depends on the billing SDK from AWS CodeArtifact. The token expires every 12h.

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
