# Apollo Deploy — Local Setup in 2 Steps

## Prerequisites

- [Docker Desktop](https://www.docker.com/products/docker-desktop/) running
- [Terraform](https://developer.hashicorp.com/terraform/install) ≥ 1.6
- [Bun](https://bun.sh) installed (`curl -fsSL https://bun.sh/install | bash`)
- NPM token for `@apollo-deploy/*` private packages (get from 1Password / team lead)

## Step 1 — Export your build tokens

```bash
export NPM_TOKEN=npm_...           # required — pulls @apollo-deploy/* packages
export CODEARTIFACT_AUTH_TOKEN=... # required only if you want Signal
                                   # run: cd apollo-signal-api && make codeartifact-token
```

## Step 2 — Clone the repo

```bash
git clone --recurse-submodules https://github.com/Apollo-Deploy/apollo-infra.git
cd apollo-infra
```

> If you already cloned without `--recurse-submodules`:
> ```bash
> git submodule update --init --recursive
> ```

## Step 3 — Run

```bash
cd infra/terraform/environments/local
terraform init
terraform apply -auto-approve
```

**That's it.** Everything else is automatic:
- All secrets are generated for you
- Images are built from source
- Databases are created and migrated
- OAuth M2M credentials are wired between services

---

## Services after setup

| Service | URL | Notes |
|---|---|---|
| Platform API | http://api.platform.localhost | Auth, users, OAuth |
| Billing API | http://localhost:3040 | Subscriptions |
| Signal API | http://api.signal.localhost | Email/SMS (if enabled) |
| Postgres | `localhost:5432` | Direct connection |
| PgBouncer | `localhost:5433` | Pooled connection |
| Redis | `localhost:6379` | |

## Without Signal (faster setup)

Signal requires a CodeArtifact token and takes longer to build.
To skip it entirely:

```bash
terraform apply -auto-approve -var="enable_signal=false"
```

Or create a `terraform.tfvars` file (copy from `terraform.tfvars.example`):
```hcl
enable_signal = false
```

## Connect to the database

```bash
# Show the auto-generated password
terraform output -json db_password

# Connect
psql postgresql://postgres:<password>@localhost:5432/apollo_deploy_platform
psql postgresql://postgres:<password>@localhost:5432/apollo_deploy_signal
```

## View M2M credentials

```bash
terraform output -json m2m_credentials
```

## Logs

```bash
docker logs -f apollo-platform
docker logs -f apollo-billing
docker logs -f apollo-signal   # if enabled
```

## Add new migrations

After adding a `.psql` file to any service's `scripts/migrations/` directory:

```bash
terraform apply -var="migration_trigger=$(date +%Y%m%d%H%M%S)"
```

## Tear down

```bash
terraform destroy -auto-approve
```

This removes all containers, the network, and volumes.
To keep the database data (volumes), remove only the containers:

```bash
docker rm -f apollo-platform apollo-billing apollo-signal apollo-platform-postgres \
             apollo-platform-pgbouncer apollo-platform-redis apollo-platform-nginx
```
