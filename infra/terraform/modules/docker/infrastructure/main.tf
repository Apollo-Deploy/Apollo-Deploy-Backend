# =============================================================================
# Infra module — PostgreSQL, PgBouncer, Redis
# Single responsibility: stateful data services only.
# API container implementations live inside their publishable profile modules.
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

# ── Volumes ───────────────────────────────────────────────────────────────────
resource "docker_volume" "postgres_data" {
  count = var.db.volume_name == null ? 1 : 0

  name = "apollo-postgres-data"
}

resource "docker_volume" "redis_data" {
  count = var.redis.volume_name == null ? 1 : 0

  name = "apollo-redis-data"
}

moved {
  from = docker_volume.postgres_data
  to   = docker_volume.postgres_data[0]
}

moved {
  from = docker_volume.redis_data
  to   = docker_volume.redis_data[0]
}

locals {
  postgres_volume_name = var.db.volume_name != null ? var.db.volume_name : docker_volume.postgres_data[0].name
  redis_volume_name    = var.redis.volume_name != null ? var.redis.volume_name : docker_volume.redis_data[0].name
  redis_acl_file       = "/usr/local/etc/redis/users.acl"
  redis_acl_content    = "user default on #${sha256(var.redis.password)} ~* &* +@all\n"
}

# ── Images ────────────────────────────────────────────────────────────────────
# Track the upstream digest so a moving tag (e.g. :latest) is actually re-pulled
# on apply instead of silently keeping the stale local image.
data "docker_registry_image" "postgres" {
  name = var.db.image
}

data "docker_registry_image" "pgbouncer" {
  name = var.pgbouncer.image
}

data "docker_registry_image" "redis" {
  name = var.redis.image
}

resource "docker_image" "postgres" {
  name          = data.docker_registry_image.postgres.name
  pull_triggers = [data.docker_registry_image.postgres.sha256_digest]
  keep_locally  = true
}

resource "docker_image" "pgbouncer" {
  name          = data.docker_registry_image.pgbouncer.name
  pull_triggers = [data.docker_registry_image.pgbouncer.sha256_digest]
  keep_locally  = true
}

resource "docker_image" "redis" {
  name          = data.docker_registry_image.redis.name
  pull_triggers = [data.docker_registry_image.redis.sha256_digest]
  keep_locally  = true
}

# ── PostgreSQL ────────────────────────────────────────────────────────────────
resource "docker_container" "postgres" {
  name    = "apollo-platform-postgres"
  image   = docker_image.postgres.image_id
  restart = "unless-stopped"

  log_driver = "local"
  log_opts = {
    max-size = "10m"
    max-file = "3"
  }

  env = [
    "POSTGRES_USER=${var.db.user}",
    "POSTGRES_PASSWORD=${var.db.password}",
    "POSTGRES_DB=${var.db.name}",
    "POSTGRES_INITDB_ARGS=--auth-host=scram-sha-256",
  ]

  dynamic "ports" {
    for_each = var.db.port_host > 0 ? [1] : []
    content {
      internal = 5432
      external = var.db.port_host
      ip       = var.db.bind_ip
    }
  }

  volumes {
    volume_name    = local.postgres_volume_name
    container_path = "/var/lib/postgresql"
  }

  networks_advanced {
    name    = var.network_name
    aliases = ["postgres"] # platform .env uses DB_HOST=postgres
  }

  # The Docker provider expresses shm_size in megabytes (not bytes).
  shm_size = 256

  healthcheck {
    test         = ["CMD-SHELL", "pg_isready -U ${var.db.user} -d ${var.db.name}"]
    interval     = "10s"
    timeout      = "5s"
    retries      = 10
    start_period = "15s"
  }

  labels {
    label = "managed-by"
    value = "terraform"
  }

  lifecycle {
    # log_opts and other runtime-set attributes drift when Docker sets its own defaults.
    # Ignore them to prevent unnecessary container recreation on subsequent applies.
    ignore_changes = [ipc_mode, runtime, stop_signal, stop_timeout]
  }
}

# ── PgBouncer ─────────────────────────────────────────────────────────────────
resource "docker_container" "pgbouncer" {
  name    = "apollo-platform-pgbouncer"
  image   = docker_image.pgbouncer.image_id
  restart = "unless-stopped"

  log_driver = "local"
  log_opts = {
    max-size = "10m"
    max-file = "3"
  }

  env = [
    "DB_HOST=apollo-platform-postgres",
    "DB_PORT=5432",
    "DB_USER=${var.db.user}",
    "DB_PASSWORD=${var.db.password}",
    "DB_NAME=${var.db.name}",
    "POOL_MODE=transaction",
    "MAX_CLIENT_CONN=${var.pgbouncer.max_client_conn}",
    "DEFAULT_POOL_SIZE=${var.pgbouncer.pool_size}",
    "RESERVE_POOL_SIZE=${var.pgbouncer.reserve_pool_size}",
    "IGNORE_STARTUP_PARAMETERS=extra_float_digits,application_name,statement_timeout",
    "AUTH_TYPE=scram-sha-256",
    "AUTH_USER=${var.db.user}",
    "AUTH_QUERY=SELECT usename, passwd FROM pg_shadow WHERE usename=$1",
    "AUTH_DBNAME=${var.db.name}",
    "ADMIN_USERS=${var.db.user}",
  ]

  dynamic "ports" {
    for_each = var.pgbouncer.port_host > 0 ? [1] : []
    content {
      internal = 5432
      external = var.pgbouncer.port_host
      ip       = var.pgbouncer.bind_ip
    }
  }

  networks_advanced {
    name = var.network_name
  }

  healthcheck {
    test         = ["CMD-SHELL", "pg_isready -h localhost -p 5432 -U ${var.db.user}"]
    interval     = "10s"
    timeout      = "5s"
    retries      = 10
    start_period = "10s"
  }

  labels {
    label = "managed-by"
    value = "terraform"
  }

  lifecycle {
    ignore_changes = [shm_size, ipc_mode, runtime, stop_signal, stop_timeout]
  }

  depends_on = [docker_container.postgres]
}

# ── Redis ─────────────────────────────────────────────────────────────────────
resource "docker_container" "redis" {
  name    = "apollo-platform-redis"
  image   = docker_image.redis.image_id
  restart = "unless-stopped"

  log_driver = "local"
  log_opts = {
    max-size = "10m"
    max-file = "3"
  }

  # Password provided to the healthcheck via env so it never appears on a command line.
  env = ["REDIS_HEALTH_PASSWORD=${var.redis.password}"]

  # Redis accepts a SHA-256 password verifier in its ACL file. Uploading only
  # the verifier keeps the plaintext password out of redis-server argv while
  # preserving normal password authentication for clients and the healthcheck.
  upload {
    content     = local.redis_acl_content
    file        = local.redis_acl_file
    permissions = "0644"
  }

  command = [
    "redis-server",
    "--aclfile", local.redis_acl_file,
    "--appendonly", "yes",
    "--maxmemory", var.redis.max_memory,
    "--maxmemory-policy", "allkeys-lru",
  ]

  dynamic "ports" {
    for_each = var.redis.port_host > 0 ? [1] : []
    content {
      internal = 6379
      external = var.redis.port_host
      ip       = var.redis.bind_ip
    }
  }

  volumes {
    volume_name    = local.redis_volume_name
    container_path = "/data"
  }

  networks_advanced {
    name    = var.network_name
    aliases = ["redis"] # platform .env uses REDIS_HOST=redis
  }

  # REDISCLI_AUTH keeps the password out of the container's process list
  # (passing it via `redis-cli -a` would expose it in `ps`).
  healthcheck {
    test         = ["CMD-SHELL", "REDISCLI_AUTH=\"$REDIS_HEALTH_PASSWORD\" redis-cli ping | grep -q PONG"]
    interval     = "10s"
    timeout      = "5s"
    retries      = 10
    start_period = "10s"
  }

  labels {
    label = "managed-by"
    value = "terraform"
  }

  lifecycle {
    ignore_changes = [shm_size, ipc_mode, runtime, stop_signal, stop_timeout]
  }
}
