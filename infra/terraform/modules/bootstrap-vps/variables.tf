# ── SSH connection ────────────────────────────────────────────────────────────
variable "vps_host" {
  type = string
}

variable "vps_user" {
  type    = string
  default = "root"
}

variable "vps_ssh_port" {
  type    = number
  default = 22
}

variable "vps_ssh_key_path" {
  type    = string
  default = "~/.ssh/id_ed25519"
}

# ── Containers ────────────────────────────────────────────────────────────────
variable "postgres_container" {
  type    = string
  default = "apollo-platform-postgres"
}

variable "platform_container" {
  type    = string
  default = "apollo-platform"
}

# ── Database ──────────────────────────────────────────────────────────────────
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
variable "platform_app_db_pass" {
  type      = string
  sensitive = true
}

variable "billing_app_db_pass" {
  type      = string
  sensitive = true
}

variable "billing_superuser_db_pass" {
  type      = string
  sensitive = true
}

variable "signal_app_db_pass" {
  type      = string
  sensitive = true
}

variable "signal_superuser_db_pass" {
  type      = string
  sensitive = true
}

variable "platform_verifier_db_pass" {
  type      = string
  sensitive = true
}

# ── OAuth clients JSON ────────────────────────────────────────────────────────
variable "oauth_clients_json" {
  description = "Contents of oauth-clients.json (the VPS variant with correct redirect URIs)"
  type        = string
}

variable "platform_url" {
  description = "Public platform URL used in the OAuth clients redirect URIs and audience"
  type        = string
}

# ── Migration paths on VPS ────────────────────────────────────────────────────
variable "platform_migrations_source_dir" {
  description = "Local path to platform migrations to upload"
  type        = string
}

variable "signal_migrations_source_dir" {
  description = "Local path to signal migrations to upload"
  type        = string
}

variable "billing_migrations_source_dir" {
  description = "Local path to billing migrations to upload"
  type        = string
}

# ── Trigger ───────────────────────────────────────────────────────────────────
variable "migration_trigger" {
  type    = string
  default = "initial"
}
