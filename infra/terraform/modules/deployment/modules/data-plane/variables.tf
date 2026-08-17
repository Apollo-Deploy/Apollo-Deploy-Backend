variable "database" {
  description = "PostgreSQL, PgBouncer, and Redis runtime contract."
  type = object({
    user             = string
    name             = string
    password         = string
    redis_password   = string
    postgres_port    = number
    pgbouncer_port   = number
    redis_port       = number
    redis_max_memory = string
  })
  sensitive = true
}

variable "persistence" {
  description = "Durable storage capability. Null selects disposable Docker-managed volumes."
  type = object({
    postgres_volume_name = string
    redis_volume_name    = string
  })
  default  = null
  nullable = true
}

variable "backup" {
  description = "Hosted PostgreSQL backup capability. Null disables backup containers."
  type = object({
    r2_account_id        = string
    r2_access_key_id     = string
    r2_secret_access_key = string
    r2_bucket            = string
    restic_password      = string
  })
  default   = null
  nullable  = true
  sensitive = true
}

variable "backup_enabled" {
  description = "Whether the backup lifecycle is part of this deployment. Kept separate from credentials so resource identity is non-sensitive."
  type        = bool
  default     = false
}
