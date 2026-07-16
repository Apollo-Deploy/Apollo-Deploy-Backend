# ── Container references ──────────────────────────────────────────────────────
variable "postgres_container" {
  description = "Name of the running Postgres container"
  type        = string
  default     = "apollo-platform-postgres"
}

variable "platform_container" {
  description = "Name of the running Platform API container"
  type        = string
  default     = "apollo-platform"
}

# ── Database connection ───────────────────────────────────────────────────────
variable "db_user" {
  type    = string
  default = "postgres"
}

variable "db_password" {
  type      = string
  sensitive = true
}

variable "db_name" {
  type    = string
  default = "apollo_deploy_platform"
}

variable "signal_db_name" {
  type    = string
  default = "apollo_deploy_signal"
}

# ── DB role passwords ─────────────────────────────────────────────────────────
variable "db_roles" {
  description = "Passwords for DB roles created by 39_db_roles.psql"
  type = object({
    platform_app       = string
    billing_app        = string
    billing_superuser  = string
    signal_app         = string
    signal_superuser   = string
    platform_verifier  = string
  })
  sensitive = true
}

# ── Migration source directories ──────────────────────────────────────────────
variable "platform_migrations_dir" {
  description = "Absolute path to apollo-platform-api/scripts/migrations"
  type        = string
}

variable "signal_migrations_dir" {
  description = "Absolute path to apollo-signal-api/scripts/migrations"
  type        = string
}

variable "billing_migrations_dir" {
  description = "Absolute path to apollo-billing-api/scripts/migrations"
  type        = string
}

# ── OAuth client registration ─────────────────────────────────────────────────
variable "oauth_clients_json_path" {
  description = "Absolute path to the oauth-clients.json file"
  type        = string
}

variable "platform_api_dir" {
  description = "Absolute path to the apollo-platform-api directory"
  type        = string
}

variable "signal_api_dir" {
  description = "Absolute path to the apollo-signal-api directory"
  type        = string
}

variable "billing_api_dir" {
  description = "Absolute path to the apollo-billing-api directory"
  type        = string
}

# ── Optional services ─────────────────────────────────────────────────────────
variable "enable_signal" {
  description = "Run signal migrations and register the signal OAuth client"
  type        = bool
  default     = true
}

# ── Triggers ──────────────────────────────────────────────────────────────────
variable "migration_trigger" {
  description = "Change this value to force migrations and OAuth registration to re-run"
  type        = string
  default     = "initial"
}
