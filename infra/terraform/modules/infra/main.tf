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
resource "docker_image" "postgres" {
  name = var.db.image
}

resource "docker_image" "pgbouncer" {
  name = var.pgbouncer.image
}

resource "docker_image" "redis" {
  name = var.redis.image
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
    container_path = "/var/lib/postgresql/data"
  }

  networks_advanced {
    name = var.network_name
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

  depends_on = [docker_container.postgres]
}

# ── Redis ─────────────────────────────────────────────────────────────────────
resource "docker_container" "redis" {
  name    = "apollo-platform-redis"
  image   = docker_image.redis.image_id
  restart = "unless-stopped"

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
    name = var.network_name
  }

  healthcheck {
    test         = ["CMD", "redis-cli", "-a", var.redis.password, "ping"]
    interval     = "10s"
    timeout      = "5s"
    retries      = 10
    start_period = "10s"
  }

  labels {
    label = "managed-by"
    value = "terraform"
  }
}
