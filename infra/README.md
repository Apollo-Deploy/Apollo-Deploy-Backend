# Apollo Deploy — Infrastructure (Terraform)

Manages all three Apollo services — **Platform**, **Signal**, and **Billing** — as Docker containers via Terraform. A single `terraform apply` provisions containers, runs database migrations, creates the signal database, and registers OAuth M2M clients between services.

```
infra/
  oauth-clients.json              # M2M client definitions (read by bootstrap)
  scripts/
    bootstrap-vps.sh              # one-time VPS prep (Docker + directories + nginx sync)
  terraform/
    modules/
      secrets/                    # auto-generates all passwords/keys (local only)
      docker-network/             # shared `apollo` Docker network
      infra/                      # postgres + pgbouncer + redis (stateful services)
      platform/                   # platform API + nginx + certbot
      signal/                     # signal API
      billing/                    # billing API
      bootstrap/                  # local: migrations + OAuth M2M (via docker exec + bun)
      bootstrap-vps/              # vps:   migrations + OAuth M2M (via SSH)
    environments/
      local/                      # builds images from source, full automation
      vps/                        # pulls from GHCR, full automation via SSH
```

---

## What `terraform apply` does automatically

```
terraform apply
│
├── Build/pull Docker images
├── Create shared `apollo` network
├── Start platform stack (postgres, pgbouncer, redis, platform API, nginx, certbot)
│
└── bootstrap module
    ├── 1. Wait for postgres to be healthy
    ├── 2. Run platform DB migrations (checksum-tracked — already-applied files are skipped)
    ├── 3. Create apollo_deploy_signal database
    ├── 4. Run signal DB migrations
    ├── 5. Apply cross-DB grants (39b_signal_grants.psql)
    ├── 6. Run billing DB migrations
    ├── 7. Wait for platform API to be healthy
    ├── 8. Register OAuth M2M clients headlessly (signal + billing)
    │        └── writes PLATFORM_CLIENT_ID/SECRET to each service's .env
    └── 9. Read back credentials → wire into signal + billing containers
         └── containers start with correct OAuth env vars automatically
```

No manual steps needed. `terraform apply` is the only command.

---

## Prerequisites

- [Terraform](https://developer.hashicorp.com/terraform/install) ≥ 1.6
- Docker Desktop / Docker Engine
- `bun` installed (for OAuth registration — local only)
- `python3` in PATH (used by the env-reading helper scripts)
- Network access to the container registries at plan time. Terraform resolves
  the current digest of each image (`docker_registry_image`) so moving tags like
  `:latest` are actually re-pulled — this means `terraform plan`/`apply` reaches
  out to Docker Hub (public images) and, on VPS, GHCR (private images).
- **VPS only:** a GitHub token with `read:packages` scope. Registry auth is
  configured on the Docker provider (`registry_auth` block), so both image pulls
  and digest lookups authenticate to GHCR automatically.

---

## Local development

```bash
# Clone with submodules (all three API repos included automatically)
git clone --recurse-submodules https://github.com/Apollo-Deploy/apollo-infra.git
cd apollo-infra

# Export build tokens
export NPM_TOKEN=npm_...              # from ~/.npmrc or npm login
export CODEARTIFACT_AUTH_TOKEN=...    # see infra/scripts/export-build-tokens.sh

# Or in one step:
#   source ../../scripts/export-build-tokens.sh

# Configure
cd terraform/environments/local
cp terraform.tfvars.example terraform.tfvars
# Fill in secrets (see comments in the file for how to generate each value)

# Deploy everything — images build, migrations run, M2M wired automatically
terraform init
terraform apply
```

After `apply` completes:

```bash
# View running services and connection strings
terraform output services
terraform output database

# Check M2M credentials (sensitive — shows registered client IDs/secrets)
terraform output -json m2m_credentials
```

### Dev mode

```bash
terraform apply -var='dev_mode=true'
```

**No Docker image build** — pulls `oven/bun` / JDK base images in seconds, bind-mounts your repo, runs `bun --watch` or `./gradlew run`. First container start may run `bun install` / Gradle once (uses `~/.npmrc` and `~/.gradle` from your machine).

### Updating local service code

Edit the service source as usual. With `dev_mode=true`, changes under `src/` reload
in the running container. Otherwise rebuild the image:

```bash
# Run from the repository root
export NPM_TOKEN=npm_...

cd infra/terraform/environments/local
terraform plan -replace=docker_image.platform
terraform apply -replace=docker_image.platform
```

The explicit `-replace` is important for source-only changes: the local image
resource tracks the Dockerfile, while the Docker build itself copies the
application source into the image. Use the corresponding resource for other
services (`docker_image.billing` or `docker_image.signal[0]`). A normal
`terraform apply` is still sufficient when the Terraform configuration itself
changed.

This replaces the service image and its dependent container only. It does not
rotate the generated secrets in `module.secrets`, delete database/Redis
volumes, or change the values passed to the recreated container. Do not delete
`terraform.tfstate`; it contains the local environment's generated secrets.

After the update:

```bash
docker ps --filter name=apollo-platform
docker logs --tail 100 apollo-platform
curl http://api.platform.localhost/health
```

### Local service URLs

| Service | URL |
|---|---|
| Platform API | http://api.platform.localhost |
| Signal API | http://api.signal.localhost |
| Billing API | http://localhost:3040 |
| Postgres | postgresql://postgres@localhost:5432/apollo_deploy_platform |
| PgBouncer | postgresql://postgres@localhost:5433/apollo_deploy_platform |
| Redis | redis://localhost:6379 |

---

## VPS deployment

```bash
# 1. One-time VPS bootstrap (installs Docker, creates dirs, syncs nginx config)
bash infra/scripts/bootstrap-vps.sh user@your-vps-ip

# 2. Upload GeoIP database
scp apollo-signal-api/geoip/dbip-city-lite.mmdb \
    user@your-vps-ip:/opt/apollo/signal/geoip/

# 3. Configure
cd infra/terraform/environments/vps
cp terraform.tfvars.example terraform.tfvars
# Fill in vps_host, base_domain, all secrets

# 4. Deploy everything — migrations run over SSH, M2M wired automatically
terraform init
terraform apply
```

That's it. Signal and billing start with their OAuth credentials already set.

### First-time TLS certificates

The `certbot` container only runs the auto-renew loop; it does **not** issue the
initial certificates. nginx mounts the cert volume read-only, so you must obtain
certs once before nginx can serve HTTPS. After the first `apply`, on the VPS:

```bash
# Issue certs for each public hostname (HTTP-01 via the shared webroot volume)
docker run --rm \
  -v apollo-letsencrypt-certs:/etc/letsencrypt \
  -v apollo-certbot-webroot:/var/www/certbot \
  certbot/certbot:v2.11.0 certonly --webroot --webroot-path /var/www/certbot \
  --email you@example.com --agree-tos --no-eff-email \
  -d api.platform.example.com \
  -d api.signal.example.com \
  -d api.billing.example.com

docker restart apollo-platform-nginx
```

Renewals are handled automatically by the long-running `certbot` container.

### Updating images

Images are tracked by their upstream digest, so a redeploy actually pulls new
content even when the tag is unchanged:

```bash
# Re-pull whatever the current tag points at (e.g. a rebuilt :latest) and restart
terraform apply

# Or deploy a specific release
terraform apply -var="image_tag=v1.2.3"
```

To publish a new Platform image from source, build and push it before applying
the VPS Terraform environment:

```bash
# Run from the repository root
export NPM_TOKEN=npm_...
export RELEASE_TAG="sha-$(git -C apollo-platform-api rev-parse --short HEAD)"

docker build \
  --secret id=npm_token,env=NPM_TOKEN \
  --tag "ghcr.io/apollo-deploy/apollo-platform-api:${RELEASE_TAG}" \
  apollo-platform-api
docker push "ghcr.io/apollo-deploy/apollo-platform-api:${RELEASE_TAG}"

cd infra/terraform/environments/vps
terraform plan -var="image_tag=${RELEASE_TAG}"
terraform apply -var="image_tag=${RELEASE_TAG}"
```

The VPS `image_tag` is shared by Platform, Signal, and Billing, so a release
tag used there must be available for every enabled service image. The GHCR
registry token needs `read:packages` for Terraform pulls and Docker push access
for publishing.

### Updating submodules to latest

```bash
# Pull latest commits for all three API repos
git submodule update --remote --merge

# Or update a single submodule
git submodule update --remote --merge apollo-billing-api
```

### Re-running migrations (e.g. after adding a new .psql file)

```bash
terraform apply -var="migration_trigger=$(date +%Y%m%d%H%M%S)"
```

---

## M2M OAuth architecture

```
                    ┌─────────────────────┐
                    │   Platform API       │
                    │  (OAuth 2.1 issuer)  │
                    │  /auth/jwks          │
                    └──────┬──────────────┘
                           │  issues JWTs
              ┌────────────┴────────────┐
              ▼                         ▼
     ┌─────────────────┐     ┌─────────────────┐
     │  Signal API      │     │  Billing API     │
     │  client_id: X    │     │  client_id: Y    │
     │  /signal/health  │────▶│  /internal/*     │
     └─────────────────┘     └─────────────────┘
              │
              ▼
     Fetches token from:
     POST /auth/oauth2/token
       grant_type=client_credentials
       client_id=X
       client_secret=...
     → JWT with iss=platform_url, aud=platform_url
     → Presented to billing's /internal/* routes
```

- **Signal → Billing**: Signal uses its `client_credentials` token (issued by Platform) when calling `billing:3040/internal/*`. Billing verifies via JWKS from Platform.
- **Billing → Platform DB**: Billing reads the platform DB using the `billing_app` role (least-privilege: only billing tables + SELECT on platform_apps).
- **Signal → Platform DB**: Signal writes to `apollo_deploy_signal` using the `signal_app` role.
- **`OAUTH_SERVICE_CLIENT_IDS`** on billing is set to Signal's `client_id` — only Signal can call billing's internal routes.

---

## Modules

### `modules/bootstrap` (local)
Chains `terraform_data` resources with `local-exec` provisioners:
- Waits for Postgres and Platform API healthchecks
- Runs migrations via `docker exec` into the Postgres container
- Runs OAuth registration via `bun run oauth:register-clients --clients oauth-clients.json`
- Surfaces credentials via `data "external"` (reads `.env` files, returns JSON)

### `modules/bootstrap-vps` (VPS)
Same logic but all execution happens over SSH. Migrations are uploaded via `scp` then run remotely. OAuth registration runs inside the `apollo-platform` container on the VPS.

### `modules/infra`
Stateful data services: postgres, pgbouncer, redis. Image tags are pinned
(`postgres:18.4-bookworm`, `edoburu/pgbouncer:v1.23.1-p2`, `redis:7-alpine`) and
each image is re-pulled when its upstream digest changes.

### `modules/platform`
Stateless services: platform API, nginx (`nginx:1.27-alpine`), certbot
(`certbot/certbot:v2.11.0`, override via `certbot_image`). The platform app image
takes an optional `image_pull_trigger` (the caller passes the registry digest so
moving tags re-pull; empty for locally built images).

### `modules/signal` / `modules/billing`
Single-container modules. Receive OAuth credentials as input variables from the
bootstrap module, plus an optional `image_pull_trigger` like `platform`.

### `modules/secrets`
Local-only. Generates every password and key via `random_password`/`random_id`
and exposes them as sensitive outputs. Values are stable in state across applies.

---

## Secrets management

Local secrets are auto-generated by `modules/secrets`. VPS secrets live in
`terraform.tfvars` (git-ignored). In both cases the generated/entered secrets are
stored **in plaintext in the state file**, so:

- Never commit `terraform.tfvars` or any `*.tfstate` file (both are git-ignored).
- For any shared or production (VPS) use, switch from the `backend "local"` block
  to an encrypted remote backend with locking. An S3 example (`encrypt = true`,
  `use_lockfile = true`) is provided, commented, in `environments/vps/main.tf`.

For teams, alternatives include:

- **Terraform Cloud / HCP** — encrypted remote state + variable store
- **AWS Secrets Manager** — `aws_secretsmanager_secret_version` data source
- **HashiCorp Vault** — `vault_generic_secret` data source

### Provider versions are locked

Each environment commits a `.terraform.lock.hcl` with checksums for linux and
darwin (amd64 + arm64). Commit lock-file changes when bumping provider versions;
run `terraform providers lock -platform=...` to refresh multi-platform hashes.

## Upgrading an existing local stack

The local environment now uses the shared `docker-network` module instead of an
inline network resource. If you have an existing local state, migrate the address
once to avoid recreating the network (and the containers attached to it):

```bash
cd terraform/environments/local
terraform state mv docker_network.apollo module.network.docker_network.apollo
```

Fresh deployments need no action.
