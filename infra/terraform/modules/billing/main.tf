# =============================================================================
# Billing module — Apollo Billing API
# Shares platform's Postgres and Redis; connects via container names.
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
  issuer_url      = var.oauth.issuer_url != "" ? var.oauth.issuer_url : var.oauth.platform_url
  valid_audiences = var.oauth.valid_audiences != "" ? var.oauth.valid_audiences : var.oauth.platform_url
  dev_command = [
    "sh", "-c",
    "apk add --no-cache git >/dev/null 2>&1 || true; chmod +x gradlew; exec ./gradlew run -Pio.ktor.development=true",
  ]
}

resource "docker_image" "billing" {
  name          = var.image
  pull_triggers = var.image_pull_trigger != "" ? [var.image_pull_trigger] : null
  keep_locally  = true
}

resource "docker_container" "billing" {
  name    = "apollo-billing"
  image   = docker_image.billing.image_id
  restart = "unless-stopped"

  stop_timeout = 30
  working_dir  = var.dev_mode ? "/app" : null
  command      = var.dev_mode ? local.dev_command : null

  env = [
    "BILLING_PORT=3040",

    # Platform DB (billing_app role)
    "PLATFORM_DB_HOST=${var.db.host}",
    "PLATFORM_DB_PORT=${var.db.port}",
    "PLATFORM_DB_NAME=${var.db.name}",
    "PLATFORM_DB_USER=${var.db.user}",
    "PLATFORM_DB_PASSWORD=${var.db.password}",

    # billing_superuser for cross-DB signal reads
    "BILLING_SUPERUSER_PASSWORD=${var.db.superuser_password}",
    "SIGNAL_DB_HOST=${var.signal_db.host}",
    "SIGNAL_DB_PORT=${var.signal_db.port}",
    "SIGNAL_DB_NAME=${var.signal_db.name}",

    # Redis
    "REDIS_HOST=${var.redis.host}",
    "REDIS_PORT=${var.redis.port}",
    "REDIS_PASSWORD=${var.redis.password}",

    # Platform / OAuth
    "PLATFORM_URL=${var.oauth.platform_url}",
    "PLATFORM_CLIENT_ID=${var.oauth.client_id}",
    "PLATFORM_CLIENT_SECRET=${var.oauth.client_secret}",
    "AUTH_JWKS_URL=",
    "AUTH_OAUTH_ISSUER_URL=${local.issuer_url}",
    "AUTH_OAUTH_VALID_AUDIENCES=${local.valid_audiences}",
    "OAUTH_SERVICE_CLIENT_IDS=${var.oauth.service_client_ids}",

    # Polar
    "POLAR_API_KEY=${var.polar.api_key}",
    "POLAR_WEBHOOK_SECRET=${var.polar.webhook_secret}",
    "POLAR_API_BASE_URL=${var.polar.base_url}",
  ]

  networks_advanced {
    name    = var.network_name
    aliases = ["billing"] # nginx config upstream uses "billing:3040"
  }

  healthcheck {
    test         = ["CMD", "wget", "-qO", "/dev/null", "http://localhost:3040/health"]
    interval     = "15s"
    timeout      = "5s"
    retries      = 5
    start_period = var.dev_mode ? "300s" : "25s"
  }

  read_only = var.dev_mode ? false : true

  dynamic "volumes" {
    for_each = var.dev_mode ? { app = var.source_dir, gradle = pathexpand("~/.gradle") } : {}
    content {
      host_path      = volumes.value
      container_path = volumes.key == "gradle" ? "/root/.gradle" : "/app"
    }
  }

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
    # `env` is intentionally NOT ignored: rotating secrets or updating OAuth
    # client IDs must recreate the container so the new values take effect.
    ignore_changes = [log_opts, log_driver, shm_size, ipc_mode, runtime, stop_signal, stop_timeout]
  }
}
