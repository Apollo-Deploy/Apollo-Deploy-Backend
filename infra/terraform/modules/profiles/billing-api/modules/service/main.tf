# =============================================================================
# Billing module — Apollo Billing API
# Shares platform's Postgres and Redis; connects via container names.
# =============================================================================

terraform {
  required_version = ">= 1.10, < 2.0"

  required_providers {
    docker = {
      source  = "kreuzwerker/docker"
      version = "3.9.0"
    }
  }
}

locals {
  issuer_url      = var.oauth.issuer_url != "" ? var.oauth.issuer_url : var.oauth.platform_audience_url
  valid_audiences = var.oauth.valid_audiences != "" ? var.oauth.valid_audiences : var.oauth.platform_audience_url
  dev_command = [
    "sh", "-c",
    "chmod +x gradlew; ./gradlew shadowJar --no-daemon --console=plain -x test && exec java -Xms64m -Xmx256m -XX:MaxMetaspaceSize=128m -jar build/libs/app.jar",
  ]
}

# Without a persistent Gradle home the dev container re-downloads the Gradle
# distribution and every dependency on each restart, which outlasts the
# healthcheck start period.
resource "docker_volume" "gradle_cache" {
  count = var.dev_mode ? 1 : 0
  name  = "apollo-billing-gradle-cache"
}

resource "docker_image" "billing" {
  name         = var.image
  keep_locally = true
}

resource "docker_container" "billing" {
  name    = "apollo-billing"
  image   = docker_image.billing.image_id
  restart = "unless-stopped"

  log_driver = "local"
  log_opts = {
    "max-size" = "10m"
    "max-file" = "3"
  }

  stop_timeout = 30
  working_dir  = var.dev_mode ? "/app" : null
  command      = var.dev_mode ? local.dev_command : null

  env = [
    "BILLING_PORT=3040",
    "APOLLO_BILLING_ENV=${var.environment}",
    "CORS_ALLOWED_DOMAIN=${var.cors_allowed_domain}",

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
    # PLATFORM_URL is the in-network token endpoint; the public URL is the JWT audience.
    "PLATFORM_URL=${var.oauth.platform_url}",
    "PLATFORM_AUDIENCE_URL=${var.oauth.platform_audience_url}",
    "PLATFORM_CLIENT_ID=${var.oauth.client_id}",
    "PLATFORM_CLIENT_SECRET=${var.oauth.client_secret}",
    "AUTH_JWKS_URL=${var.oauth.jwks_url}",
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
    test         = ["CMD", "wget", "-qO", "/dev/null", "http://127.0.0.1:3040/health"]
    interval     = "15s"
    timeout      = "5s"
    retries      = 5
    start_period = var.dev_mode ? "5m0s" : "25s"
  }

  read_only = var.dev_mode ? false : true

  dynamic "volumes" {
    for_each = var.dev_mode ? { app = var.source_dir } : {}
    content {
      host_path      = volumes.value
      container_path = "/app"
    }
  }

  dynamic "volumes" {
    for_each = var.dev_mode ? { sdk = dirname(var.source_dir) } : {}
    content {
      host_path      = "${volumes.value}/sdks/kotlin-m2m-oauth"
      container_path = "/sdks/kotlin-m2m-oauth"
      # The composite Gradle build writes its project cache under .gradle.
      read_only = false
    }
  }

  dynamic "volumes" {
    for_each = var.dev_mode ? { gradle_cache = docker_volume.gradle_cache[0].name } : {}
    content {
      volume_name    = volumes.value
      container_path = "/root/.gradle"
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

  labels {
    label = "org.opencontainers.image.revision"
    value = var.source_commit != "" ? var.source_commit : "local"
  }

  lifecycle {
    # `env` is intentionally NOT ignored: rotating secrets or updating OAuth
    # client IDs must recreate the container so the new values take effect.
    ignore_changes = [shm_size, ipc_mode, runtime, stop_signal, stop_timeout]
  }
}
