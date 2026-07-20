# =============================================================================
# Apollo Deploy — Local Developer Environment
#
# ONE COMMAND: terraform init && terraform apply -auto-approve
#
# What happens automatically:
#   ✓ Secrets generated (module "secrets")
#   ✓ Docker images built from source
#   ✓ Postgres, PgBouncer, Redis started (module "infra")
#   ✓ Platform API + nginx started (module "platform")
#   ✓ Migrations run + OAuth M2M clients registered (module "bootstrap")
#   ✓ Platform restarted with OAuth IDs
#   ✓ Billing started with auto-wired credentials (module "billing")
#   ✓ Signal started when enable_signal=true (module "signal")
# =============================================================================

terraform {
  required_version = ">= 1.6"

  required_providers {
    docker = {
      source  = "kreuzwerker/docker"
      version = "~> 3.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }

  backend "local" {
    path = "terraform.tfstate"
  }
}

provider "docker" {
  host = "unix:///var/run/docker.sock"
}

# ── Absolute paths ────────────────────────────────────────────────────────────
locals {
  repo_root    = abspath("${path.root}/../../../../")
  platform_dir = "${local.repo_root}/apollo-platform-api"
  signal_dir   = "${local.repo_root}/apollo-signal-api"
  billing_dir  = "${local.repo_root}/apollo-billing-api"
  infra_dir    = "${local.repo_root}/infra"

  # Match scripts/nginx/conf.d/10-dev.conf (mkcert HTTPS on *.apollodeploy.local).
  # Cookie domain / PLATFORM_URL must use the same registrable domain or browsers
  # reject Set-Cookie (e.g. Domain=.localhost on api.platform.apollodeploy.local).
  base_domain      = "apollodeploy.local"
  platform_url     = "https://api.platform.${local.base_domain}"
  billing_internal = "http://apollo-billing:3040"

  # dev_mode: pull base images only — no docker build (seconds, not minutes).
  dev_platform_image = "oven/bun:1.3.11-alpine"
  dev_jvm_image      = "eclipse-temurin:21-jdk-alpine"
}

# =============================================================================
# SECRETS — auto-generated on first apply, stable in state thereafter
# =============================================================================

module "secrets" {
  source = "../../modules/secrets"
}

# =============================================================================
# DOCKER IMAGES — built from each service's Dockerfile
# =============================================================================

resource "docker_image" "platform" {
  count = var.dev_mode ? 0 : 1
  name  = "apollo-platform:local"
  build {
    context    = local.platform_dir
    dockerfile = "Dockerfile"
    target     = "production"
    build_args = {
      BUN_INSTALL_DEBUG = var.debug ? "1" : "0"
    }
    build_log_file = var.debug ? "/tmp/apollo-platform-build.log" : null
    secrets {
      id  = "npm_token"
      env = "NPM_TOKEN"
    }
    label = { "managed-by" = "terraform", "env" = "local" }
  }
  triggers = {
    dockerfile = filesha1("${local.platform_dir}/Dockerfile")
  }
}

resource "docker_image" "billing" {
  count = var.dev_mode ? 0 : 1
  name  = "apollo-billing:local"
  build {
    context    = local.billing_dir
    dockerfile = "Dockerfile"
    label      = { "managed-by" = "terraform", "env" = "local" }
  }
  triggers = {
    dockerfile = filesha1("${local.billing_dir}/Dockerfile")
  }
}

resource "docker_image" "signal" {
  count = var.enable_signal && !var.dev_mode ? 1 : 0
  name  = "apollo-signal:local"
  build {
    context    = local.signal_dir
    dockerfile = "Dockerfile"
    secrets {
      id  = "codeartifact_token"
      env = "CODEARTIFACT_AUTH_TOKEN"
    }
    label = { "managed-by" = "terraform", "env" = "local" }
  }
  triggers = {
    dockerfile = filesha1("${local.signal_dir}/Dockerfile")
  }
}

# =============================================================================
# NETWORK — shared module (same definition used by the VPS environment)
# =============================================================================

module "network" {
  source = "../../modules/docker-network"
}

# =============================================================================
# INFRA — Postgres, PgBouncer, Redis
# =============================================================================

module "infra" {
  source = "../../modules/infra"

  network_name = module.network.network_name

  db = {
    password  = module.secrets.db_password
    port_host = 5432 # expose for TablePlus / psql
  }

  pgbouncer = {
    port_host = 5433 # expose pooled connections on different port
  }

  redis = {
    password   = module.secrets.redis_password
    port_host  = 6379
    max_memory = "256mb"
  }
}

# =============================================================================
# PLATFORM — Platform API + nginx
# =============================================================================

module "platform" {
  source = "../../modules/platform"

  network_name = module.network.network_name
  image        = var.dev_mode ? local.dev_platform_image : docker_image.platform[0].image_id
  dev_mode     = var.dev_mode
  source_dir   = local.platform_dir

  db = {
    host     = module.infra.pgbouncer_container_name
    password = module.secrets.db_password
  }

  redis = {
    host     = module.infra.redis_container_name
    password = module.secrets.redis_password
  }

  auth = {
    platform_url         = local.platform_url
    platform_public_url  = local.platform_url
    cors_origins         = "https://app.${local.base_domain},https://auth.${local.base_domain},https://account.${local.base_domain},https://signal.${local.base_domain}"
    session_secret       = module.secrets.session_secret
    cookie_secret        = module.secrets.auth_cookie_secret
    secure_cookies       = true
    cookie_domain        = ".${local.base_domain}"
    login_url            = "https://auth.${local.base_domain}/login"
    consent_url          = "https://auth.${local.base_domain}/oauth/consent"
    disable_origin_check = false
    disable_csrf_check   = false
  }

  kms = {
    encryption_key = module.secrets.encryption_key
    key_v1         = module.secrets.kms_key_v1
    root_key_b64   = module.secrets.kms_root_key_b64
    token_enc_salt = module.secrets.token_enc_salt_b64
  }

  db_roles = {
    platform_app      = module.secrets.platform_app_db_pass
    billing_app       = module.secrets.billing_app_db_pass
    billing_superuser = module.secrets.billing_superuser_db_pass
    signal_app        = module.secrets.signal_app_db_pass
    signal_superuser  = module.secrets.signal_superuser_db_pass
    platform_verifier = module.secrets.platform_verifier_db_pass
  }

  service = {
    node_env                = "development"
    internal_service_secret = module.secrets.internal_service_secret
    billing_base_url        = local.billing_internal
    metrics_enabled         = false
  }

  nginx = {
    conf_dir = "${local.platform_dir}/scripts/nginx"
  }

  depends_on = [module.infra]
}

# =============================================================================
# BOOTSTRAP — migrations + OAuth M2M registration
# =============================================================================

module "bootstrap" {
  source = "../../modules/bootstrap"

  postgres_container = module.infra.postgres_container_name
  platform_container = module.platform.platform_container_name

  db_password    = module.secrets.db_password
  redis_password = module.secrets.redis_password
  signal_db_name = "apollo_deploy_signal"

  db_roles = {
    platform_app      = module.secrets.platform_app_db_pass
    billing_app       = module.secrets.billing_app_db_pass
    billing_superuser = module.secrets.billing_superuser_db_pass
    signal_app        = module.secrets.signal_app_db_pass
    signal_superuser  = module.secrets.signal_superuser_db_pass
    platform_verifier = module.secrets.platform_verifier_db_pass
  }

  platform_migrations_dir = "${local.platform_dir}/scripts/migrations"
  signal_migrations_dir   = "${local.signal_dir}/scripts/migrations"
  billing_migrations_dir  = "${local.billing_dir}/scripts/migrations"

  oauth_clients_json_path = "${local.infra_dir}/oauth-clients.json"
  platform_api_dir        = local.platform_dir
  signal_api_dir          = local.signal_dir
  billing_api_dir         = local.billing_dir

  enable_signal     = var.enable_signal
  migration_trigger = var.migration_trigger

  depends_on = [module.platform]
}

# ── Restart platform after bootstrap writes OAuth IDs ─────────────────────────
resource "terraform_data" "platform_oauth_restart" {
  triggers_replace = [
    module.bootstrap.oauth_trusted_client_ids,
    module.bootstrap.oauth_service_client_ids,
  ]

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-BASH
      set -euo pipefail
      TRUSTED="${module.bootstrap.oauth_trusted_client_ids}"
      if [ -z "$TRUSTED" ] || [ "$TRUSTED" = "null" ]; then
        echo "==> [platform] No OAuth IDs yet — skipping restart."
        exit 0
      fi
      echo "==> [platform] Restarting to pick up OAuth client IDs..."
      docker restart apollo-platform
      echo "==> [platform] Restart done."
    BASH
  }

  depends_on = [module.bootstrap]
}

# =============================================================================
# BILLING
# =============================================================================

module "billing" {
  source = "../../modules/billing"

  network_name = module.network.network_name
  image        = var.dev_mode ? local.dev_jvm_image : docker_image.billing[0].image_id
  dev_mode     = var.dev_mode
  source_dir   = local.billing_dir

  db = {
    password           = module.secrets.billing_app_db_pass
    superuser_password = module.secrets.billing_superuser_db_pass
  }

  redis = {
    password = module.secrets.redis_password
  }

  oauth = {
    platform_url       = local.platform_url
    client_id          = module.bootstrap.billing_platform_client_id
    client_secret      = module.bootstrap.billing_platform_client_secret
    service_client_ids = var.enable_signal ? module.bootstrap.signal_platform_client_id : ""
  }

  polar = {
    api_key        = var.polar_api_key
    webhook_secret = var.polar_webhook_secret
  }

  depends_on = [terraform_data.platform_oauth_restart]
}

# =============================================================================
# SIGNAL (optional)
# =============================================================================

module "signal" {
  count  = var.enable_signal ? 1 : 0
  source = "../../modules/signal"

  network_name = module.network.network_name
  image        = var.dev_mode ? local.dev_jvm_image : docker_image.signal[0].image_id
  dev_mode     = var.dev_mode
  source_dir   = local.signal_dir

  db = {
    password = module.secrets.signal_app_db_pass
    sslmode  = "disable"
  }

  redis = {
    password = module.secrets.redis_password
  }

  oauth = {
    platform_audience_url   = local.platform_url
    client_id               = module.bootstrap.signal_platform_client_id
    client_secret           = module.bootstrap.signal_platform_client_secret
    issuer_url              = local.platform_url
    valid_audiences         = local.platform_url
    internal_service_secret = module.secrets.internal_service_secret
    session_secret          = module.secrets.session_secret
    secure_cookies          = true
  }

  aws = {
    access_key_id     = var.aws_access_key_id
    secret_access_key = var.aws_secret_access_key
    account_id        = var.aws_account_id
    sqs_webhook_url   = var.sqs_webhook_queue_url
    sqs_scheduled_url = var.sqs_scheduled_email_queue_url
    sqs_domain_url    = var.sqs_domain_verification_queue_url
  }

  storage = {
    provider         = var.template_media_provider
    bucket           = var.s3_template_media_bucket
    public_base_url  = var.template_media_public_base_url
    r2_account_id    = var.r2_account_id
    r2_access_key_id = var.r2_access_key_id
    r2_secret_key    = var.r2_secret_access_key
  }

  features = {
    events_signing_secret = var.signal_events_signing_secret
    koog_api_key          = var.koog_api_key
    tracking_base_url     = "http://signal.localhost"
    billing_base_url      = local.billing_internal
  }

  sms = {
    telnyx_api_key              = var.telnyx_api_key
    telnyx_messaging_profile_id = var.telnyx_messaging_profile_id
  }

  geoip_host_path = "${local.signal_dir}/geoip"

  depends_on = [terraform_data.platform_oauth_restart]
}
