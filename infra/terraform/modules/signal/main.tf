# =============================================================================
# Signal module — Apollo Signal API service
# Joins the shared apollo network; depends on platform infra.
# =============================================================================

terraform {
  required_providers {
    docker = {
      source  = "kreuzwerker/docker"
      version = "~> 3.0"
    }
  }
}

locals {
  dev_command = [
    "sh", "-c",
    "apk add --no-cache git >/dev/null 2>&1 || true; chmod +x gradlew; exec ./gradlew run -Pio.ktor.development=true",
  ]
}

resource "docker_image" "signal" {
  name          = var.image
  pull_triggers = var.image_pull_trigger != "" ? [var.image_pull_trigger] : null
  keep_locally  = true
}

resource "docker_container" "signal" {
  name    = "apollo-signal"
  image   = docker_image.signal.image_id
  restart = "unless-stopped"

  stop_timeout = 30
  working_dir  = var.dev_mode ? "/app" : null
  command      = var.dev_mode ? local.dev_command : null

  env = [
    # Service
    "APOLLO_SIGNAL_ENV=production",
    "SIGNAL_PORT=3030",
    "SIGNAL_IMPORT_WORKERS_ENABLED=true",

    # Database
    "SIGNAL_DB_HOST=${var.db.host}",
    "SIGNAL_DB_PORT=${var.db.port}",
    "SIGNAL_DB_NAME=${var.db.name}",
    "SIGNAL_DB_USER=${var.db.user}",
    "SIGNAL_DB_PASSWORD=${var.db.password}",
    "SIGNAL_DB_SSLMODE=${var.db.sslmode}",

    # Redis
    "REDIS_HOST=${var.redis.host}",
    "REDIS_PORT=${var.redis.port}",
    "REDIS_PASSWORD=${var.redis.password}",

    # Platform / OAuth
    "PLATFORM_BASE_URL=${var.oauth.platform_internal_url}",
    "PLATFORM_AUDIENCE_URL=${var.oauth.platform_audience_url}",
    "PLATFORM_CLIENT_ID=${var.oauth.client_id}",
    "PLATFORM_CLIENT_SECRET=${var.oauth.client_secret}",
    "AUTH_OAUTH_ISSUER_URL=${var.oauth.issuer_url}",
    "AUTH_OAUTH_VALID_AUDIENCES=${var.oauth.valid_audiences}",
    "INTERNAL_SERVICE_SECRET=${var.oauth.internal_service_secret}",
    "SESSION_SECRET=${var.oauth.session_secret}",
    "AUTH_SECURE_COOKIES=${var.oauth.secure_cookies}",
    "CORS_ORIGINS=${var.oauth.cors_origins}",

    # AWS
    "APOLLO_SIGNAL_AWS_REGION=${var.aws.region}",
    "APOLLO_SIGNAL_AWS_ACCESS_KEY_ID=${var.aws.access_key_id}",
    "APOLLO_SIGNAL_AWS_SECRET_ACCESS_KEY=${var.aws.secret_access_key}",
    "APOLLO_SIGNAL_AWS_ACCOUNT_ID=${var.aws.account_id}",
    "APOLLO_SIGNAL_SES_CONFIGURATION_SET=${var.aws.ses_config_set}",
    "APOLLO_SIGNAL_SQS_WEBHOOK_QUEUE_URL=${var.aws.sqs_webhook_url}",
    "APOLLO_SIGNAL_SQS_SCHEDULED_EMAIL_QUEUE_URL=${var.aws.sqs_scheduled_url}",
    "APOLLO_SIGNAL_SQS_DOMAIN_VERIFICATION_QUEUE_URL=${var.aws.sqs_domain_url}",

    # Storage (R2 / S3)
    "APOLLO_SIGNAL_TEMPLATE_MEDIA_PROVIDER=${var.storage.provider}",
    "APOLLO_SIGNAL_S3_TEMPLATE_MEDIA_BUCKET=${var.storage.bucket}",
    "APOLLO_SIGNAL_TEMPLATE_MEDIA_PUBLIC_BASE_URL=${var.storage.public_base_url}",
    "APOLLO_SIGNAL_TEMPLATE_MEDIA_R2_ACCOUNT_ID=${var.storage.r2_account_id}",
    "APOLLO_SIGNAL_TEMPLATE_MEDIA_R2_ACCESS_KEY_ID=${var.storage.r2_access_key_id}",
    "APOLLO_SIGNAL_TEMPLATE_MEDIA_R2_SECRET_ACCESS_KEY=${var.storage.r2_secret_key}",

    # Features / Events / Webhooks
    "APOLLO_SIGNAL_EVENTS_SIGNING_SECRET=${var.features.events_signing_secret}",
    "SIGNAL_WEBHOOK_SECRET_KEY=${var.features.webhook_secret_key}",
    "SIGNAL_BYOK_SECRET_KEY=${var.features.byok_secret_key}",
    "SIGNAL_BYOK_CFN_TEMPLATE_URL=${var.features.byok_cfn_template_url}",

    # Tracking / AI
    "SIGNAL_TRACKING_BASE_URL=${var.features.tracking_base_url}",
    "SIGNAL_TRACKING_CNAME_TARGET=${var.features.tracking_cname_target}",
    "APOLLO_SIGNAL_KOOG_API_KEY=${var.features.koog_api_key}",
    "APOLLO_SIGNAL_KOOG_MODEL=${var.features.koog_model}",

    # GeoIP
    "SIGNAL_GEOIP_DB_PATH=/data/geoip/dbip-city-lite.mmdb",

    # Billing
    "BILLING_BASE_URL=${var.features.billing_base_url}",

    # No-proxy for internal container names
    "NO_PROXY=localhost,127.0.0.1,apollo-billing,apollo-platform,apollo-platform-postgres,apollo-platform-redis,192.168.0.0/16,10.0.0.0/8",
    "no_proxy=localhost,127.0.0.1,apollo-billing,apollo-platform,apollo-platform-postgres,apollo-platform-redis,192.168.0.0/16,10.0.0.0/8",

    # SMS
    "TELNYX_API_KEY=${var.sms.telnyx_api_key}",
    "TELNYX_MESSAGING_PROFILE_ID=${var.sms.telnyx_messaging_profile_id}",
  ]

  dynamic "volumes" {
    for_each = var.dev_mode ? { app = var.source_dir, gradle = pathexpand("~/.gradle") } : {}
    content {
      host_path      = volumes.value
      container_path = volumes.key == "gradle" ? "/root/.gradle" : "/app"
    }
  }

  volumes {
    host_path      = var.geoip_host_path
    container_path = "/data/geoip"
    read_only      = true
  }

  networks_advanced {
    name    = var.network_name
    aliases = ["signal"] # nginx config upstream uses "signal:3030"
  }

  healthcheck {
    test         = ["CMD", "wget", "--no-verbose", "--tries=1", "--spider", "http://localhost:3030/signal/health"]
    interval     = "15s"
    timeout      = "5s"
    retries      = 5
    start_period = var.dev_mode ? "300s" : "25s"
  }

  read_only = var.dev_mode ? false : true

  mounts {
    target = "/tmp"
    type   = "tmpfs"
    tmpfs_options {
      size_bytes = 104857600 # 100 MB
    }
  }

  security_opts = ["no-new-privileges:true"]

  capabilities {
    drop = ["ALL"]
  }

  labels {
    label = "managed-by"
    value = "terraform"
  }

  lifecycle {
    ignore_changes = [log_opts, log_driver, shm_size, ipc_mode, runtime, stop_signal, stop_timeout]
  }
}
