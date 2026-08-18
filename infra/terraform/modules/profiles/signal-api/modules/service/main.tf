# =============================================================================
# Signal module — Apollo Signal API service
# Joins the shared apollo network; depends on platform infra.
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
  dev_command = [
    "sh", "-c",
    "chmod +x gradlew; export APOLLO_SIGNAL_ENV=development; ./gradlew shadowJar --no-daemon --console=plain -x test -Dorg.gradle.jvmargs='-Xmx3g -XX:MaxMetaspaceSize=512m' && exec java -Xms64m -Xmx256m -XX:MaxMetaspaceSize=128m -jar build/libs/app.jar",
  ]
}

resource "docker_volume" "gradle_cache" {
  count = var.dev_mode ? 1 : 0
  name  = "apollo-signal-gradle-cache"
}

resource "docker_image" "signal" {
  name         = var.image
  keep_locally = true
}

resource "docker_container" "signal" {
  name    = "apollo-signal"
  image   = docker_image.signal.image_id
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
    # Service
    "APOLLO_SIGNAL_ENV=${var.dev_mode ? "development" : "production"}",
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
    # Signal reads PLATFORM_URL for its in-network OAuth token endpoint. The
    # public URL remains separate because it is the JWT audience.
    "PLATFORM_URL=${var.oauth.platform_internal_url}",
    "PLATFORM_AUDIENCE_URL=${var.oauth.platform_audience_url}",
    "PLATFORM_CLIENT_ID=${var.oauth.client_id}",
    "PLATFORM_CLIENT_SECRET=${var.oauth.client_secret}",
    "AUTH_OAUTH_ISSUER_URL=${var.oauth.issuer_url}",
    "AUTH_OAUTH_VALID_AUDIENCES=${var.oauth.valid_audiences}",
    "AUTH_JWKS_URL=${var.oauth.auth_jwks_url}",
    "OAUTH_SERVICE_CLIENT_IDS=${var.oauth.service_client_ids}",
    "INTERNAL_SERVICE_SECRET=${var.oauth.internal_service_secret}",
    "SESSION_SECRET=${var.oauth.session_secret}",
    "AUTH_SECURE_COOKIES=${var.oauth.secure_cookies}",
    "CORS_ORIGINS=${var.oauth.cors_origins}",

    # AWS
    "APOLLO_SIGNAL_AWS_REGION=${var.aws.region}",
    "APOLLO_SIGNAL_AWS_REGIONS=${jsonencode([for region in sort(tolist(var.aws.extra_regions)) : { region = region }])}",
    "APOLLO_SIGNAL_AWS_ACCESS_KEY_ID=${var.aws.access_key_id}",
    "APOLLO_SIGNAL_AWS_SECRET_ACCESS_KEY=${var.aws.secret_access_key}",
    "APOLLO_SIGNAL_AWS_ACCOUNT_ID=${var.aws.account_id}",
    "APOLLO_SIGNAL_SES_CONFIGURATION_SET=${var.aws.ses_config_set}",
    "APOLLO_SIGNAL_SQS_SCHEDULED_EMAIL_QUEUE_URL=${var.aws.sqs_scheduled_email_url}",
    "APOLLO_SIGNAL_DMARC_INBOUND_QUEUE_URL=${var.aws.sqs_dmarc_inbound_url}",
    "APOLLO_SIGNAL_EVENTS_TOPIC_ARN=${var.aws.sns_event_topic_arn}",
    "APOLLO_SIGNAL_EVENTS_TOPIC_ARNS=${join(",", sort(tolist(var.aws.sns_event_topic_arns)))}",
    "APOLLO_SIGNAL_DMARC_INBOUND_TOPIC_ARN=${var.aws.sns_dmarc_inbound_topic_arn}",
    "APOLLO_SIGNAL_S3_CONTACT_IMAGES_BUCKET=${var.aws.s3_contact_images_bucket}",
    "APOLLO_SIGNAL_DMARC_INBOUND_BUCKET=${var.aws.s3_dmarc_inbound_bucket}",
    "APOLLO_SIGNAL_DMARC_INGESTION_ENABLED=${var.aws.dmarc_ingestion_enabled}",
    "APOLLO_SIGNAL_S3_PROJECT_ARCHIVES_BUCKET=${var.aws.s3_project_archives_bucket}",
    "APOLLO_SIGNAL_S3_PROJECT_ARCHIVES_KMS_KEY_ARN=${var.aws.s3_project_archives_kms_key_arn}",

    # Signal uploads use AWS S3. R2 is intentionally not exposed by this module.
    "APOLLO_SIGNAL_TEMPLATE_MEDIA_PROVIDER=s3",
    "APOLLO_SIGNAL_S3_TEMPLATE_MEDIA_BUCKET=${var.storage.bucket}",
    "APOLLO_SIGNAL_TEMPLATE_MEDIA_PUBLIC_BASE_URL=${var.storage.public_base_url}",

    # Features / Events / Webhooks
    "APOLLO_SIGNAL_EVENTS_SIGNING_SECRET=${var.features.events_signing_secret}",
    "SIGNAL_WEBHOOK_SECRET_KEY=${var.features.webhook_secret_key}",
    "KMS_ROOT_KEY_B64=${var.features.import_credentials_key}",

    # Tracking / AI
    "SIGNAL_TRACKING_BASE_URL=${var.features.tracking_base_url}",
    "APOLLO_SIGNAL_KOOG_API_KEY=${var.features.koog_api_key}",
    "APOLLO_SIGNAL_KOOG_MODEL=${var.features.koog_model}",

    # GeoIP
    "SIGNAL_GEOIP_DB_PATH=/data/geoip/dbip-city-lite.mmdb",

    # Billing
    "BILLING_BASE_URL=${var.features.billing_base_url}",

    # No-proxy for internal container names
    "NO_PROXY=localhost,127.0.0.1,apollo-billing,apollo-platform,apollo-platform-postgres,apollo-platform-redis,192.168.0.0/16,10.0.0.0/8",
    "no_proxy=localhost,127.0.0.1,apollo-billing,apollo-platform,apollo-platform-postgres,apollo-platform-redis,192.168.0.0/16,10.0.0.0/8",

  ]

  dynamic "volumes" {
    for_each = var.dev_mode ? { app = var.source_dir } : {}
    content {
      host_path      = volumes.value
      container_path = "/app"
    }
  }

  dynamic "volumes" {
    for_each = var.dev_mode ? {
      "kotlin-m2m-oauth"         = "${dirname(var.source_dir)}/sdks/kotlin-m2m-oauth"
      "apollo-commons"           = "${dirname(var.source_dir)}/sdks/apollo-commons"
      "kotlin-api-rate-limiting" = "${dirname(var.source_dir)}/sdks/kotlin-api-rate-limiting"
    } : {}
    content {
      host_path      = volumes.value
      container_path = "/sdks/${volumes.key}"
      # The composite Gradle builds write their project caches under .gradle.
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
    test         = ["CMD", "wget", "--no-verbose", "--tries=1", "--spider", "http://127.0.0.1:3030/v1/health"]
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

  labels {
    label = "org.opencontainers.image.revision"
    value = var.source_commit != "" ? var.source_commit : "local"
  }

  lifecycle {
    ignore_changes = [shm_size, ipc_mode, runtime, stop_signal, stop_timeout]
  }
}
