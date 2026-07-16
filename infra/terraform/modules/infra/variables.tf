variable "network_name" {
  type        = string
  description = "Shared Docker network name"
}

variable "db" {
  description = "PostgreSQL configuration"
  type = object({
    image     = optional(string, "postgres:18.4-bookworm")
    user      = optional(string, "postgres")
    password  = string
    name      = optional(string, "apollo_deploy_platform")
    port_host = optional(number, 0)
  })
  sensitive = true
}

variable "pgbouncer" {
  description = "PgBouncer connection pooler configuration"
  type = object({
    image             = optional(string, "edoburu/pgbouncer:latest")
    port_host         = optional(number, 0)
    max_client_conn   = optional(number, 1000)
    pool_size         = optional(number, 25)
    reserve_pool_size = optional(number, 5)
  })
  default = {}
}

variable "redis" {
  description = "Redis configuration"
  type = object({
    image      = optional(string, "redis:7-alpine")
    password   = string
    port_host  = optional(number, 0)
    max_memory = optional(string, "512mb")
  })
  sensitive = true
}
