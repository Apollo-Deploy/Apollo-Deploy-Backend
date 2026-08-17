variable "network_name" {
  type        = string
  description = "Shared Docker network name"

  validation {
    condition     = trimspace(var.network_name) != ""
    error_message = "network_name must not be empty."
  }
}

variable "db" {
  description = "PostgreSQL configuration"
  type = object({
    image       = optional(string, "postgres:18.4-bookworm@sha256:882236b897e39051d2368c5ccc6cda944904723506b2dfc97f2a8f5bc9afa382")
    user        = optional(string, "postgres")
    password    = string
    name        = optional(string, "apollo_deploy_platform")
    port_host   = optional(number, 0)
    bind_ip     = optional(string, "127.0.0.1")
    volume_name = optional(string)
  })
  sensitive = true

  validation {
    condition     = can(regex("@sha256:[0-9a-f]{64}$", var.db.image))
    error_message = "db.image must be pinned by a lowercase sha256 manifest digest."
  }

  validation {
    condition = (
      floor(var.db.port_host) == var.db.port_host &&
      var.db.port_host >= 0 && var.db.port_host <= 65535
    )
    error_message = "db.port_host must be 0 or an integer between 1 and 65535."
  }

  validation {
    condition     = can(regex("^(?:[0-9]{1,3}\\.){3}[0-9]{1,3}$", var.db.bind_ip))
    error_message = "db.bind_ip must be an IPv4 address."
  }

  validation {
    condition = (
      can(regex("^[A-Za-z_][A-Za-z0-9_]*$", var.db.name)) &&
      can(regex("^[A-Za-z_][A-Za-z0-9_]*$", var.db.user))
    )
    error_message = "db.name and db.user must be valid unquoted PostgreSQL identifiers."
  }

  validation {
    condition     = length(var.db.password) >= 16
    error_message = "db.password must contain at least 16 characters."
  }

  validation {
    condition     = var.db.volume_name == null || can(regex("^[A-Za-z0-9][A-Za-z0-9_.-]*$", var.db.volume_name))
    error_message = "db.volume_name must be null or a valid Docker volume name."
  }
}

variable "pgbouncer" {
  description = "PgBouncer connection pooler configuration"
  type = object({
    image             = optional(string, "edoburu/pgbouncer:v1.23.1-p2@sha256:122bac472cfb0b92dca81a72421c93c3c5a840899e2002690a39742427cfcd49")
    port_host         = optional(number, 0)
    bind_ip           = optional(string, "127.0.0.1")
    max_client_conn   = optional(number, 1000)
    pool_size         = optional(number, 25)
    reserve_pool_size = optional(number, 5)
  })
  default = {}

  validation {
    condition     = can(regex("@sha256:[0-9a-f]{64}$", var.pgbouncer.image))
    error_message = "pgbouncer.image must be pinned by a lowercase sha256 manifest digest."
  }

  validation {
    condition = alltrue([
      floor(var.pgbouncer.port_host) == var.pgbouncer.port_host,
      var.pgbouncer.port_host >= 0 && var.pgbouncer.port_host <= 65535,
      var.pgbouncer.max_client_conn > 0,
      var.pgbouncer.pool_size > 0,
      var.pgbouncer.reserve_pool_size >= 0,
    ])
    error_message = "PgBouncer ports and pool sizes must be valid non-negative values, with positive connection and pool limits."
  }

  validation {
    condition     = can(regex("^(?:[0-9]{1,3}\\.){3}[0-9]{1,3}$", var.pgbouncer.bind_ip))
    error_message = "pgbouncer.bind_ip must be an IPv4 address."
  }
}

variable "redis" {
  description = "Redis configuration"
  type = object({
    image       = optional(string, "redis:7.4.7-alpine@sha256:02f2cc4882f8bf87c79a220ac958f58c700bdec0dfb9b9ea61b62fb0e8f1bfcf")
    password    = string
    port_host   = optional(number, 0)
    bind_ip     = optional(string, "127.0.0.1")
    max_memory  = optional(string, "512mb")
    volume_name = optional(string)
  })
  sensitive = true

  validation {
    condition     = can(regex("@sha256:[0-9a-f]{64}$", var.redis.image))
    error_message = "redis.image must be pinned by a lowercase sha256 manifest digest."
  }

  validation {
    condition = (
      floor(var.redis.port_host) == var.redis.port_host &&
      var.redis.port_host >= 0 && var.redis.port_host <= 65535
    )
    error_message = "redis.port_host must be 0 or an integer between 1 and 65535."
  }

  validation {
    condition     = can(regex("^(?:[0-9]{1,3}\\.){3}[0-9]{1,3}$", var.redis.bind_ip))
    error_message = "redis.bind_ip must be an IPv4 address."
  }

  validation {
    condition     = length(var.redis.password) >= 16
    error_message = "redis.password must contain at least 16 characters."
  }

  validation {
    condition     = can(regex("^[1-9][0-9]*(b|kb|mb|gb)$", lower(var.redis.max_memory)))
    error_message = "redis.max_memory must be a positive byte value such as 512mb or 1gb."
  }

  validation {
    condition     = var.redis.volume_name == null || can(regex("^[A-Za-z0-9][A-Za-z0-9_.-]*$", var.redis.volume_name))
    error_message = "redis.volume_name must be null or a valid Docker volume name."
  }
}
