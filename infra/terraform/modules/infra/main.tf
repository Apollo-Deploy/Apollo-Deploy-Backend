# =============================================================================
# Infra module — PostgreSQL, PgBouncer, Redis
# Single responsibility: stateful data services only.
# The platform API and nginx live in modules/platform.
# =============================================================================

terraform {
  required_providers {
    docker = {
      source  = "kreuzwerker/docker"
      version = "~> 3.0"
    }
  }
}

# ── Volumes ───────────────────────────────────────────────────────────────────
resource "docker_volume" "postgres_data" {
  name = "apollo-postgres-data"
}

resource "docker_volume" "redis_data" {
  name = "apollo-redis-data"
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
    }
  }

  volumes {
    volume_name    = docker_volume.postgres_data.name
    container_path = "/var/lib/postgresql"
  }

  networks_advanced {
    name    = var.network_name
    aliases = ["postgres"] # platform .env uses DB_HOST=postgres
  }

  shm_size = 268435456 # 256 MB — needed for parallel operations

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
    ignore_changes = [log_opts, log_driver, shm_size, ipc_mode, runtime, stop_signal, stop_timeout]
  }
}

# ── PgBouncer ─────────────────────────────────────────────────────────────────
resource "docker_container" "pgbouncer" {
  name    = "apollo-platform-pgbouncer"
  image   = docker_image.pgbouncer.image_id
  restart = "unless-stopped"

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
    "ADMIN_USERS=${var.db.user}",
  ]

  dynamic "ports" {
    for_each = var.pgbouncer.port_host > 0 ? [1] : []
    content {
      internal = 5432
      external = var.pgbouncer.port_host
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
    ignore_changes = [log_opts, log_driver, shm_size, ipc_mode, runtime, stop_signal, stop_timeout]
  }

  depends_on = [docker_container.postgres]
}

# ── Redis ─────────────────────────────────────────────────────────────────────
resource "docker_container" "redis" {
  name    = "apollo-platform-redis"
  image   = docker_image.redis.image_id
  restart = "unless-stopped"

  # Password provided to the healthcheck via env so it never appears on a command line.
  env = ["REDIS_HEALTH_PASSWORD=${var.redis.password}"]

  command = [
    "redis-server",
    "--requirepass", var.redis.password,
    "--appendonly", "yes",
    "--maxmemory", var.redis.max_memory,
    "--maxmemory-policy", "allkeys-lru",
  ]

  dynamic "ports" {
    for_each = var.redis.port_host > 0 ? [1] : []
    content {
      internal = 6379
      external = var.redis.port_host
    }
  }

  volumes {
    volume_name    = docker_volume.redis_data.name
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
    ignore_changes = [log_opts, log_driver, shm_size, ipc_mode, runtime, stop_signal, stop_timeout]
  }
}
