variable "network_name" {
  type        = string
  description = "Name or ID of the Docker network shared with PostgreSQL."

  validation {
    condition     = can(regex("^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$", var.network_name))
    error_message = "network_name must be a valid Docker network name or ID (1-128 letters, digits, dots, underscores, or hyphens)."
  }
}

variable "postgres_host" {
  type        = string
  description = "PostgreSQL host reachable from the supplied Docker network."

  validation {
    condition     = can(regex("^[A-Za-z0-9_.:-]{1,253}$", var.postgres_host))
    error_message = "postgres_host must be a DNS name or IP address without whitespace or shell metacharacters."
  }
}

variable "postgres_port" {
  type        = number
  description = "PostgreSQL TCP port."
  default     = 5432

  validation {
    condition     = floor(var.postgres_port) == var.postgres_port && var.postgres_port >= 1 && var.postgres_port <= 65535
    error_message = "postgres_port must be an integer between 1 and 65535."
  }
}

variable "postgres_user" {
  type        = string
  description = "PostgreSQL role used by pg_dumpall. It normally needs superuser privileges for a complete cluster dump."

  validation {
    condition     = can(regex("^[A-Za-z_][A-Za-z0-9_]{0,62}$", var.postgres_user))
    error_message = "postgres_user must be a valid unquoted PostgreSQL identifier no longer than 63 characters."
  }
}

variable "postgres_password" {
  type        = string
  description = "Password for postgres_user. It is passed to libpq through PGPASSWORD and is never placed in the container command."
  sensitive   = true

  validation {
    condition     = length(var.postgres_password) >= 16
    error_message = "postgres_password must contain at least 16 characters."
  }
}

variable "postgres_database" {
  type        = string
  description = "Database used for pg_dumpall's initial connection."
  default     = "postgres"

  validation {
    condition     = can(regex("^[A-Za-z_][A-Za-z0-9_]{0,62}$", var.postgres_database))
    error_message = "postgres_database must be a valid unquoted PostgreSQL identifier no longer than 63 characters."
  }
}

variable "postgres_sslmode" {
  type        = string
  description = "libpq SSL mode used for the backup connection."
  default     = "prefer"

  validation {
    condition = contains([
      "disable",
      "allow",
      "prefer",
      "require",
      "verify-ca",
      "verify-full",
    ], var.postgres_sslmode)
    error_message = "postgres_sslmode must be one of disable, allow, prefer, require, verify-ca, or verify-full."
  }
}

variable "connection_timeout_seconds" {
  type        = number
  description = "libpq connection timeout in seconds."
  default     = 10

  validation {
    condition = (
      floor(var.connection_timeout_seconds) == var.connection_timeout_seconds &&
      var.connection_timeout_seconds >= 1 &&
      var.connection_timeout_seconds <= 300
    )
    error_message = "connection_timeout_seconds must be an integer between 1 and 300."
  }
}

variable "postgres_client_image" {
  type        = string
  description = "Official PostgreSQL client image pinned by an immutable manifest digest."
  default     = "postgres:18.4-bookworm@sha256:882236b897e39051d2368c5ccc6cda944904723506b2dfc97f2a8f5bc9afa382"

  validation {
    condition = (
      length(trimspace(var.postgres_client_image)) == length(var.postgres_client_image) &&
      !can(regex("[[:space:]]", var.postgres_client_image)) &&
      can(regex("@sha256:[0-9a-f]{64}$", var.postgres_client_image))
    )
    error_message = "postgres_client_image must be pinned by a lowercase sha256 manifest digest."
  }
}

variable "container_name" {
  type        = string
  description = "Name assigned to the backup container."
  default     = "apollo-postgres-backup"

  validation {
    condition     = can(regex("^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$", var.container_name))
    error_message = "container_name must be a valid Docker container name no longer than 128 characters."
  }
}

variable "backup_volume_name" {
  type        = string
  description = "Name assigned to the durable Docker volume containing backup files."
  default     = "apollo-postgres-backups"

  validation {
    condition     = can(regex("^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$", var.backup_volume_name))
    error_message = "backup_volume_name must be a valid Docker volume name no longer than 128 characters."
  }
}

variable "schedule" {
  description = "Backup, retry, retention, and healthcheck timing. Intervals are measured from the end of an attempt."
  type = object({
    interval_seconds                 = optional(number, 86400)
    retry_interval_seconds           = optional(number, 300)
    retention_count                  = optional(number, 7)
    max_backup_age_seconds           = optional(number, 93600)
    healthcheck_interval_seconds     = optional(number, 60)
    healthcheck_timeout_seconds      = optional(number, 10)
    healthcheck_retries              = optional(number, 3)
    healthcheck_start_period_seconds = optional(number, 300)
  })
  default = {}

  validation {
    condition = alltrue([
      floor(var.schedule.interval_seconds) == var.schedule.interval_seconds,
      var.schedule.interval_seconds >= 60,
      var.schedule.interval_seconds <= 2678400,
      floor(var.schedule.retry_interval_seconds) == var.schedule.retry_interval_seconds,
      var.schedule.retry_interval_seconds >= 10,
      var.schedule.retry_interval_seconds <= var.schedule.interval_seconds,
      floor(var.schedule.retention_count) == var.schedule.retention_count,
      var.schedule.retention_count >= 1,
      var.schedule.retention_count <= 365,
      floor(var.schedule.max_backup_age_seconds) == var.schedule.max_backup_age_seconds,
      var.schedule.max_backup_age_seconds >= 120,
      var.schedule.max_backup_age_seconds <= 5356800,
      floor(var.schedule.healthcheck_interval_seconds) == var.schedule.healthcheck_interval_seconds,
      var.schedule.healthcheck_interval_seconds >= 10,
      var.schedule.healthcheck_interval_seconds <= 3600,
      floor(var.schedule.healthcheck_timeout_seconds) == var.schedule.healthcheck_timeout_seconds,
      var.schedule.healthcheck_timeout_seconds >= 1,
      var.schedule.healthcheck_timeout_seconds <= 60,
      floor(var.schedule.healthcheck_retries) == var.schedule.healthcheck_retries,
      var.schedule.healthcheck_retries >= 1,
      var.schedule.healthcheck_retries <= 20,
      floor(var.schedule.healthcheck_start_period_seconds) == var.schedule.healthcheck_start_period_seconds,
      var.schedule.healthcheck_start_period_seconds >= 0,
      var.schedule.healthcheck_start_period_seconds <= 86400,
    ])
    error_message = "schedule values must be whole seconds/counts within their documented operational bounds; retry_interval_seconds must not exceed interval_seconds."
  }

  validation {
    condition = (
      var.schedule.max_backup_age_seconds >=
      var.schedule.interval_seconds + var.schedule.healthcheck_interval_seconds
    )
    error_message = "schedule.max_backup_age_seconds must be at least interval_seconds plus healthcheck_interval_seconds."
  }
}

variable "labels" {
  type        = map(string)
  description = "Additional labels applied to both the container and backup volume. Module-owned labels take precedence."
  default     = {}

  validation {
    condition = alltrue([
      for key, value in var.labels :
      length(trimspace(key)) > 0 && length(key) <= 128 && length(value) <= 4096
    ])
    error_message = "Label keys must be non-empty and at most 128 characters; values must be at most 4096 characters."
  }
}

variable "offsite" {
  description = "Optional encrypted restic repository backed by R2's S3-compatible endpoint."
  type = object({
    repository        = string
    aws_access_key_id = string
    aws_secret_key    = string
    restic_password   = string
    image             = optional(string, "restic/restic:0.18.1@sha256:39d9072fb5651c80d75c7a811612eb60b4c06b32ffe87c2e9f3c7222e1797e76")
    interval_seconds  = optional(number, 3600)
  })
  sensitive = true
  default   = null
  validation {
    condition = var.offsite == null || (
      startswith(var.offsite.repository, "s3:https://") &&
      length(trimspace(var.offsite.repository)) == length(var.offsite.repository) &&
      !can(regex("[[:space:]]", var.offsite.repository)) &&
      length(trimspace(var.offsite.aws_access_key_id)) >= 8 &&
      length(var.offsite.aws_secret_key) >= 16 &&
      length(var.offsite.restic_password) >= 20
    )
    error_message = "offsite requires a whitespace-free HTTPS S3 repository, an 8+ character access key, a 16+ character secret key, and a 20+ character restic password."
  }

  validation {
    condition = var.offsite == null || (
      length(trimspace(var.offsite.image)) == length(var.offsite.image) &&
      !can(regex("[[:space:]]", var.offsite.image)) &&
      can(regex("@sha256:[0-9a-f]{64}$", var.offsite.image))
    )
    error_message = "offsite.image must be pinned by a lowercase sha256 manifest digest."
  }

  validation {
    condition = var.offsite == null || (
      floor(var.offsite.interval_seconds) == var.offsite.interval_seconds &&
      var.offsite.interval_seconds >= 60 &&
      var.offsite.interval_seconds <= 86400
    )
    error_message = "offsite.interval_seconds must be a whole number between 60 and 86400."
  }
}
variable "offsite_enabled" {
  type        = bool
  default     = false
  description = "Enable the encrypted restic R2 uploader."

  validation {
    condition     = !var.offsite_enabled || var.offsite != null
    error_message = "offsite must be provided when offsite_enabled is true."
  }
}
