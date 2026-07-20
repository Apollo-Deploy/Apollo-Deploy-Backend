# =============================================================================
# Platform module — Platform API + nginx + certbot
# Stateless services only. Data services live in modules/infra.
# Consumes: infra module outputs (container names for ordering).
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
  platform_url = var.auth.platform_url
  public_url   = coalesce(var.auth.platform_public_url, var.auth.platform_url)

  dev_command = [
    "sh", "-c",
    "if [ ! -d node_modules ]; then bun install --frozen-lockfile --production --ignore-scripts; fi; exec bun --watch run src/index.ts",
  ]
}

# ── Volumes ───────────────────────────────────────────────────────────────────
resource "docker_volume" "letsencrypt_certs" {
  name = "apollo-letsencrypt-certs"
}

resource "docker_volume" "certbot_webroot" {
  name = "apollo-certbot-webroot"
}

# ── Images ────────────────────────────────────────────────────────────────────
# The platform image may be a locally built image ID (local env) or a registry
# reference (VPS env). When it's a registry ref, the caller passes the upstream
# digest as image_pull_trigger so a moving tag actually re-pulls on apply.
resource "docker_image" "platform" {
  name          = var.image
  pull_triggers = var.image_pull_trigger != "" ? [var.image_pull_trigger] : null
  keep_locally  = true
}

# nginx and certbot are always pulled from a registry — track their digests
# directly so pinned/floating tags re-pull when the upstream image changes.
data "docker_registry_image" "nginx" {
  name = var.nginx.image
}

data "docker_registry_image" "certbot" {
  name = var.certbot_image
}

resource "docker_image" "nginx" {
  name          = data.docker_registry_image.nginx.name
  pull_triggers = [data.docker_registry_image.nginx.sha256_digest]
  keep_locally  = true
}

resource "docker_image" "certbot" {
  name          = data.docker_registry_image.certbot.name
  pull_triggers = [data.docker_registry_image.certbot.sha256_digest]
  keep_locally  = true
}

# ── Platform API ──────────────────────────────────────────────────────────────
resource "docker_container" "platform" {
  name    = "apollo-platform"
  image   = docker_image.platform.image_id
  restart = "unless-stopped"

  stop_timeout = 30
  working_dir  = var.dev_mode ? "/app" : null
  command      = var.dev_mode ? local.dev_command : null

  env = [
    "NODE_ENV=${var.service.node_env}",
    "PORT=3000",
    "HOST=0.0.0.0",

    # Auth / URLs
    "PLATFORM_URL=${local.platform_url}",
    "PLATFORM_PUBLIC_URL=${local.public_url}",
    "CORS_ORIGINS=${var.auth.cors_origins}",
    "SESSION_SECRET=${var.auth.session_secret}",
    "AUTH_COOKIE_SECRET=${var.auth.cookie_secret}",
    "AUTH_SECURE_COOKIES=${var.auth.secure_cookies}",
    "AUTH_COOKIE_DOMAIN=${var.auth.cookie_domain}",
    "AUTH_LOGIN_URL=${var.auth.login_url}",
    "AUTH_CONSENT_URL=${var.auth.consent_url}",
    "AUTH_DISABLE_ORIGIN_CHECK=${var.auth.disable_origin_check}",
    "AUTH_DISABLE_CSRF_CHECK=${var.auth.disable_csrf_check}",

    # Database (points at pgbouncer)
    "DB_HOST=${var.db.host}",
    "DB_PORT=${var.db.port}",
    "DB_USER=${var.db.user}",
    "DB_PASSWORD=${var.db.password}",
    "DB_NAME=${var.db.name}",
    "DB_POOL_MAX=10",

    # Signal DB name (platform needs to know it for cross-DB queries)
    "SIGNAL_DB_NAME=${var.service.signal_db_name}",

    # Redis
    "REDIS_HOST=${var.redis.host}",
    "REDIS_PORT=${var.redis.port}",
    "REDIS_PASSWORD=${var.redis.password}",
    "REDIS_TLS=false",

    # KMS / Encryption
    "ENCRYPTION_KEY=${var.kms.encryption_key}",
    "KMS_ACTIVE_KEY_ID=v1",
    "KMS_KEY_V1=${var.kms.key_v1}",
    "KMS_ROOT_KEY_B64=${var.kms.root_key_b64}",
    "TOKEN_ENC_SALT_B64=${var.kms.token_enc_salt}",

    # Service
    "INTERNAL_SERVICE_SECRET=${var.service.internal_service_secret}",
    "BILLING_BASE_URL=${var.service.billing_base_url}",
    "METRICS_ENABLED=${var.service.metrics_enabled}",

    # DB role passwords (consumed by migrations + init scripts)
    "PLATFORM_APP_DB_PASS=${var.db_roles.platform_app}",
    "BILLING_APP_DB_PASS=${var.db_roles.billing_app}",
    "BILLING_SUPERUSER_DB_PASS=${var.db_roles.billing_superuser}",
    "SIGNAL_APP_DB_PASS=${var.db_roles.signal_app}",
    "SIGNAL_SUPERUSER_DB_PASS=${var.db_roles.signal_superuser}",
    "PLATFORM_VERIFIER_DB_PASS=${var.db_roles.platform_verifier}",
  ]

  networks_advanced {
    name    = var.network_name
    aliases = ["platform"] # nginx config upstream uses "platform:3000"
  }

  healthcheck {
    test         = var.dev_mode ? ["CMD-SHELL", "wget -qO- http://localhost:3000/health >/dev/null 2>&1 || exit 1"] : ["CMD", "curl", "-f", "http://localhost:3000/health"]
    interval     = "15s"
    timeout      = "5s"
    retries      = 5
    start_period = var.dev_mode ? "180s" : "30s"
  }

  read_only = var.dev_mode ? false : true

  dynamic "volumes" {
    for_each = var.dev_mode ? { app = var.source_dir, npmrc = pathexpand("~/.npmrc") } : {}
    content {
      host_path      = volumes.value
      container_path = volumes.key == "npmrc" ? "/app/.npmrc" : "/app"
      read_only      = volumes.key == "npmrc"
    }
  }

  mounts {
    target = "/tmp"
    type   = "tmpfs"
    tmpfs_options {
      size_bytes = 104857600 # 100 MB
    }
  }

  dynamic "mounts" {
    for_each = var.dev_mode ? [] : [1]
    content {
      target = "/app/.cache"
      type   = "tmpfs"
      tmpfs_options {
        size_bytes = 52428800 # 50 MB
      }
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

  # Ordering relative to infra (Postgres/Redis) is handled by the caller via
  # `depends_on = [module.infra]` on this module. Container health is ensured
  # by the bootstrap module's wait steps.
}

# ── nginx ─────────────────────────────────────────────────────────────────────
resource "docker_container" "nginx" {
  name    = "apollo-platform-nginx"
  image   = docker_image.nginx.image_id
  restart = "unless-stopped"

  stop_timeout = 10

  ports {
    internal = 80
    external = var.nginx.http_port
  }

  ports {
    internal = 443
    external = var.nginx.https_port
  }

  volumes {
    host_path      = "${var.nginx.conf_dir}/nginx.conf"
    container_path = "/etc/nginx/nginx.conf"
    read_only      = true
  }

  volumes {
    host_path      = "${var.nginx.conf_dir}/conf.d"
    container_path = "/etc/nginx/conf.d"
    read_only      = true
  }

  volumes {
    host_path      = "${var.nginx.conf_dir}/snippets"
    container_path = "/etc/nginx/snippets"
    read_only      = true
  }

  volumes {
    host_path      = "${var.nginx.conf_dir}/certs"
    container_path = "/etc/nginx/certs"
    read_only      = true
  }

  volumes {
    host_path      = "${var.nginx.conf_dir}/local"
    container_path = "/etc/nginx/local"
    read_only      = true
  }

  volumes {
    volume_name    = docker_volume.letsencrypt_certs.name
    container_path = "/etc/letsencrypt"
    read_only      = true
  }

  volumes {
    volume_name    = docker_volume.certbot_webroot.name
    container_path = "/var/www/certbot"
    read_only      = true
  }

  networks_advanced {
    name = var.network_name
  }

  healthcheck {
    test         = ["CMD", "wget", "--quiet", "--tries=1", "--spider", "http://localhost/nginx-health"]
    interval     = "15s"
    timeout      = "5s"
    retries      = 3
    start_period = "10s"
  }

  read_only = true

  mounts {
    target = "/var/cache/nginx"
    type   = "tmpfs"
    tmpfs_options {
      size_bytes = 104857600 # 100 MB
    }
  }

  mounts {
    target = "/var/run"
    type   = "tmpfs"
    tmpfs_options {
      size_bytes = 10485760 # 10 MB
    }
  }

  mounts {
    target = "/tmp"
    type   = "tmpfs"
    tmpfs_options {
      size_bytes = 52428800 # 50 MB
    }
  }

  security_opts = ["no-new-privileges:true"]

  capabilities {
    drop = ["ALL"]
    add  = ["CHOWN", "SETUID", "SETGID", "NET_BIND_SERVICE"]
  }

  labels {
    label = "managed-by"
    value = "terraform"
  }

  lifecycle {
    # capabilities format (CHOWN vs CAP_CHOWN) and ports drift from Docker defaults.
    ignore_changes = [log_opts, log_driver, shm_size, ipc_mode, runtime, stop_signal, stop_timeout, capabilities, ports]
  }

  depends_on = [docker_container.platform]
}

# ── certbot ───────────────────────────────────────────────────────────────────
resource "docker_container" "certbot" {
  name    = "apollo-platform-certbot"
  image   = docker_image.certbot.image_id
  restart = "unless-stopped"

  # Auto-renew loop: check every 12 hours
  entrypoint = ["/bin/sh", "-c"]
  command = [
    "trap exit TERM; while :; do certbot renew --webroot --webroot-path /var/www/certbot --quiet; sleep 43200; done"
  ]

  volumes {
    volume_name    = docker_volume.letsencrypt_certs.name
    container_path = "/etc/letsencrypt"
  }

  volumes {
    volume_name    = docker_volume.certbot_webroot.name
    container_path = "/var/www/certbot"
  }

  networks_advanced {
    name = var.network_name
  }

  labels {
    label = "managed-by"
    value = "terraform"
  }

  lifecycle {
    ignore_changes = [log_opts, log_driver, shm_size, ipc_mode, runtime, stop_signal, stop_timeout]
  }
}
