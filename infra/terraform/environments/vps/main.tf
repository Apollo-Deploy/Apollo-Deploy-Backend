# =============================================================================
# VPS environment — all services run on a remote server via Docker over SSH.
# Images are pulled from GHCR. Migrations and OAuth M2M are fully automated.
#
# Prerequisites:
#   - Bootstrap the VPS first:  bash infra/scripts/bootstrap-vps.sh user@host
#   - Docker installed on VPS and SSH key access configured
#   - Copy terraform.tfvars.example → terraform.tfvars and fill in values
#
# Usage:
#   terraform init
#   terraform plan
#   terraform apply
# =============================================================================

terraform {
  required_version = ">= 1.6"

  required_providers {
    docker = {
      source  = "kreuzwerker/docker"
      version = "~> 3.0"
    }
  }

  # State contains every generated secret in plaintext. For any shared or
  # production use, switch to an encrypted remote backend with locking rather
  # than the local file below:
  #
  # backend "s3" {
  #   bucket       = "my-terraform-state"
  #   key          = "apollo/vps/terraform.tfstate"
  #   region       = "us-east-1"
  #   encrypt      = true          # server-side encryption at rest
  #   use_lockfile = true          # S3-native state locking (Terraform >= 1.10)
  # }

  backend "local" {
    path = "terraform.tfstate"
  }
}

# ── Docker provider — connects to VPS via SSH ─────────────────────────────────
# Registry auth is configured on the provider (kreuzwerker/docker has no
# standalone docker_registry_auth resource). This lets both image pulls and the
# docker_registry_image data sources below authenticate to GHCR.
provider "docker" {
  host     = "ssh://${var.vps_user}@${var.vps_host}:${var.vps_ssh_port}"
  ssh_opts = ["-i", var.vps_ssh_key_path, "-o", "StrictHostKeyChecking=accept-new"]

  registry_auth {
    address  = "ghcr.io"
    username = var.ghcr_username
    password = var.ghcr_token
  }
}

# ── Locals ────────────────────────────────────────────────────────────────────
locals {
  repo_root    = abspath("${path.root}/../../../../")
  platform_dir = "${local.repo_root}/apollo-platform-api"
  signal_dir   = "${local.repo_root}/apollo-signal-api"
  billing_dir  = "${local.repo_root}/apollo-billing-api"
  infra_dir    = "${local.repo_root}/infra"

  platform_url = "https://api.platform.${var.base_domain}"

  platform_image = "${var.ghcr_registry}/apollo-platform-api:${var.image_tag}"
  signal_image   = "${var.ghcr_registry}/apollo-signal-api:${var.image_tag}"
  billing_image  = "${var.ghcr_registry}/apollo-billing-api:${var.image_tag}"

  oauth_clients_json = jsonencode([
    {
      key          = "signal"
      name         = "Apollo Signal"
      isPublic     = false
      grantTypes   = ["authorization_code", "refresh_token", "client_credentials"]
      skipConsent  = true
      redirectUris = ["https://app.${var.base_domain}"]
      scope        = "openid profile email offline_access signals:read signals:evaluate signals:write"
      envTarget = {
        service         = "signal"
        clientIdVar     = "PLATFORM_CLIENT_ID"
        clientSecretVar = "PLATFORM_CLIENT_SECRET"
      }
    },
    {
      key          = "billing"
      name         = "Apollo Billing"
      isPublic     = false
      grantTypes   = ["authorization_code", "refresh_token", "client_credentials"]
      skipConsent  = true
      redirectUris = ["https://app.${var.base_domain}"]
      scope        = "openid profile email offline_access billing:read billing:write"
      envTarget = {
        service         = "billing"
        clientIdVar     = "PLATFORM_CLIENT_ID"
        clientSecretVar = "PLATFORM_CLIENT_SECRET"
      }
    }
  ])
}

# =============================================================================
# IMAGE DIGESTS — resolve the current GHCR digest for each service image so a
# moving tag (e.g. :latest) is actually re-pulled on apply instead of silently
# running a stale local image.
# =============================================================================

data "docker_registry_image" "platform" {
  name = local.platform_image
}

data "docker_registry_image" "signal" {
  name = local.signal_image
}

data "docker_registry_image" "billing" {
  name = local.billing_image
}

# =============================================================================
# NETWORK
# =============================================================================

module "network" {
  source = "../../modules/docker-network"
}

# =============================================================================
# INFRA — Postgres, PgBouncer, Redis (no host port binding in production)
# =============================================================================

module "infra" {
  source = "../../modules/infra"

  network_name = module.network.network_name

  db = {
    user      = var.db_user
    password  = var.db_password
    name      = var.db_name
    port_host = 0 # no host binding in production
  }

  pgbouncer = {
    port_host = 0
  }

  redis = {
    password  = var.redis_password
    port_host = 0
  }
}

# =============================================================================
# PLATFORM — Platform API + nginx + certbot
# =============================================================================

module "platform" {
  source = "../../modules/platform"

  network_name       = module.network.network_name
  image              = local.platform_image
  image_pull_trigger = data.docker_registry_image.platform.sha256_digest

  db = {
    host     = module.infra.pgbouncer_container_name
    user     = var.db_user
    password = var.db_password
    name     = var.db_name
  }

  redis = {
    host     = module.infra.redis_container_name
    password = var.redis_password
  }

  auth = {
    platform_url   = local.platform_url
    cors_origins   = "https://app.${var.base_domain},https://auth.${var.base_domain}"
    session_secret = var.session_secret
    cookie_secret  = var.auth_cookie_secret
    secure_cookies = true
    cookie_domain  = ".${var.base_domain}"
    login_url      = "https://app.${var.base_domain}/login"
    consent_url    = "https://app.${var.base_domain}/oauth/consent"
  }

  kms = {
    encryption_key = var.encryption_key
    key_v1         = var.kms_key_v1
    root_key_b64   = var.kms_root_key_b64
    token_enc_salt = var.token_enc_salt_b64
  }

  db_roles = {
    platform_app      = var.platform_app_db_pass
    billing_app       = var.billing_app_db_pass
    billing_superuser = var.billing_superuser_db_pass
    signal_app        = var.signal_app_db_pass
    signal_superuser  = var.signal_superuser_db_pass
    platform_verifier = var.platform_verifier_db_pass
  }

  service = {
    internal_service_secret = var.internal_service_secret
    billing_base_url        = "http://apollo-billing:3040"
    metrics_enabled         = var.metrics_enabled
  }

  nginx = {
    conf_dir          = "/opt/apollo/platform/nginx"
    letsencrypt_email = var.letsencrypt_email
  }

  depends_on = [module.infra]
}

# =============================================================================
# BOOTSTRAP — migrations + OAuth M2M (runs via bootstrap-vps over SSH)
# =============================================================================

module "bootstrap" {
  source = "../../modules/bootstrap-vps"

  vps_host         = var.vps_host
  vps_user         = var.vps_user
  vps_ssh_port     = var.vps_ssh_port
  vps_ssh_key_path = var.vps_ssh_key_path

  postgres_container = module.infra.postgres_container_name
  platform_container = module.platform.platform_container_name

  db_user     = var.db_user
  db_password = var.db_password
  db_name     = var.db_name

  platform_app_db_pass      = var.platform_app_db_pass
  billing_app_db_pass       = var.billing_app_db_pass
  billing_superuser_db_pass = var.billing_superuser_db_pass
  signal_app_db_pass        = var.signal_app_db_pass
  signal_superuser_db_pass  = var.signal_superuser_db_pass
  platform_verifier_db_pass = var.platform_verifier_db_pass

  oauth_clients_json = local.oauth_clients_json
  platform_url       = local.platform_url

  platform_migrations_source_dir = "${local.platform_dir}/scripts/migrations"
  signal_migrations_source_dir   = "${local.signal_dir}/scripts/migrations"
  billing_migrations_source_dir  = "${local.billing_dir}/scripts/migrations"

  signal_db_name    = "apollo_deploy_signal"
  migration_trigger = var.migration_trigger

  depends_on = [module.platform]
}

# =============================================================================
# SIGNAL
# =============================================================================

module "signal" {
  source = "../../modules/signal"

  network_name       = module.network.network_name
  image              = local.signal_image
  image_pull_trigger = data.docker_registry_image.signal.sha256_digest

  db = {
    password = var.signal_app_db_pass
    sslmode  = "disable"
  }

  redis = {
    password = var.redis_password
  }

  oauth = {
    platform_audience_url   = local.platform_url
    client_id               = module.bootstrap.signal_platform_client_id
    client_secret           = module.bootstrap.signal_platform_client_secret
    issuer_url              = local.platform_url
    valid_audiences         = local.platform_url
    internal_service_secret = var.internal_service_secret
    session_secret          = var.session_secret
    secure_cookies          = true
    cors_origins            = "https://app.${var.base_domain}"
  }

  aws = {
    region            = var.aws_region
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
    events_signing_secret = var.events_signing_secret
    webhook_secret_key    = var.signal_webhook_secret_key
    byok_secret_key       = var.signal_byok_secret_key
    byok_cfn_template_url = var.signal_byok_cfn_template_url
    tracking_base_url     = "https://signal.${var.base_domain}"
    tracking_cname_target = var.signal_tracking_cname_target
    koog_api_key          = var.koog_api_key
    billing_base_url      = "http://apollo-billing:3040"
  }

  sms = {
    telnyx_api_key              = var.telnyx_api_key
    telnyx_messaging_profile_id = var.telnyx_messaging_profile_id
  }

  geoip_host_path = "/opt/apollo/signal/geoip"

  depends_on = [module.bootstrap]
}

# =============================================================================
# BILLING
# =============================================================================

module "billing" {
  source = "../../modules/billing"

  network_name       = module.network.network_name
  image              = local.billing_image
  image_pull_trigger = data.docker_registry_image.billing.sha256_digest

  db = {
    password           = var.billing_app_db_pass
    superuser_password = var.billing_superuser_db_pass
  }

  redis = {
    password = var.redis_password
  }

  oauth = {
    platform_url  = local.platform_url
    client_id     = module.bootstrap.billing_platform_client_id
    client_secret = module.bootstrap.billing_platform_client_secret
    # Signal is allowed to call billing's /internal/* routes
    service_client_ids = module.bootstrap.signal_platform_client_id
  }

  polar = {
    api_key        = var.polar_api_key
    webhook_secret = var.polar_webhook_secret
  }

  depends_on = [module.bootstrap]
}
