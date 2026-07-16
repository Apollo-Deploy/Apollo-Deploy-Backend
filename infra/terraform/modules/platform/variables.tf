variable "network_name" {
  type        = string
  description = "Shared Docker network all Apollo services join"
}

variable "image" {
  type        = string
  description = "Platform API Docker image reference"
}

variable "db" {
  description = "Database connection — should point at pgbouncer"
  type = object({
    host     = string
    port     = optional(number, 5432)
    user     = optional(string, "postgres")
    password = string
    name     = optional(string, "apollo_deploy_platform")
  })
  sensitive = true
}

variable "redis" {
  description = "Redis connection"
  type = object({
    host     = string
    port     = optional(number, 6379)
    password = string
  })
  sensitive = true
}

variable "auth" {
  description = "Authentication and session configuration"
  type = object({
    platform_url         = string
    platform_public_url  = optional(string)
    cors_origins         = optional(string, "")
    session_secret       = string
    cookie_secret        = string
    secure_cookies       = optional(bool, true)
    cookie_domain        = optional(string, ".apollodeploy.com")
    login_url            = string
    consent_url          = string
    disable_origin_check = optional(bool, false)
    disable_csrf_check   = optional(bool, false)
  })
  sensitive = true
}

variable "kms" {
  description = "KMS and encryption key material"
  type = object({
    encryption_key = string
    key_v1         = string
    root_key_b64   = string
    token_enc_salt = string
  })
  sensitive = true
}

variable "db_roles" {
  description = "DB role passwords created by migrations"
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

variable "service" {
  description = "General service configuration"
  type = object({
    node_env                = optional(string, "production")
    internal_service_secret = string
    signal_db_name          = optional(string, "apollo_deploy_signal")
    billing_base_url        = optional(string, "http://apollo-billing:3040")
    metrics_enabled         = optional(bool, false)
  })
  sensitive = true
}

variable "nginx" {
  description = "nginx and TLS configuration"
  type = object({
    image             = optional(string, "nginx:1.27-alpine")
    conf_dir          = string
    http_port         = optional(number, 80)
    https_port        = optional(number, 443)
    letsencrypt_email = optional(string, "")
  })
}

variable "infra_container_names" {
  description = "Container names from the infra module — used for depends_on ordering"
  type = object({
    pgbouncer = string
    redis     = string
  })
}
