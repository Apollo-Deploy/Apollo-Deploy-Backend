variable "network_name" { type = string }

variable "certificate_volumes" {
  type    = object({ certificates = optional(string), webroot = optional(string) })
  default = {}
}

variable "image" { type = string }

variable "source_commit" {
  description = "Full source commit represented by a production image; empty for a locally built development image."
  type        = string
  default     = ""

  validation {
    condition     = var.source_commit == "" || can(regex("^[0-9a-f]{40}$", var.source_commit))
    error_message = "source_commit must be empty for local development or a full 40-character lowercase hexadecimal Git commit."
  }
}

variable "cors_allowed_domain" {
  description = "HTTPS apex domain whose complete subdomain tree may make credentialed browser requests."
  type        = string

  validation {
    condition     = can(regex("^(?:[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?[.])+(?:[A-Za-z]{2,63})$", var.cors_allowed_domain))
    error_message = "cors_allowed_domain must be a fully qualified DNS domain without a scheme or wildcard."
  }
}

variable "certbot_image" {
  type    = string
  default = "certbot/certbot:v2.11.0@sha256:ddf9e5d226a56e886986838fa0ebedc0237511c78664352e8d0f4346ee022cd8"

  validation {
    condition     = can(regex("@sha256:[0-9a-f]{64}$", var.certbot_image))
    error_message = "certbot_image must be pinned by a lowercase sha256 manifest digest."
  }
}

variable "db" {
  sensitive = true
  type = object({
    host              = string
    port              = optional(number, 5432)
    user              = optional(string, "platform_app")
    password          = string
    name              = optional(string, "apollo_deploy_platform")
    verifier_enabled  = optional(bool, true)
    verifier_host     = string
    verifier_user     = optional(string, "platform_verifier")
    verifier_password = string
  })
}

variable "redis" {
  sensitive = true
  type = object({
    host     = string
    port     = optional(number, 6379)
    password = string
  })
}

variable "auth" {
  sensitive = true
  type = object({
    platform_url         = string
    platform_public_url  = optional(string)
    session_secret       = string
    cookie_secret        = string
    secure_cookies       = optional(bool, true)
    cookie_domain        = optional(string, ".apollodeploy.com")
    login_url            = string
    consent_url          = string
    disable_origin_check = optional(bool, false)
    disable_csrf_check   = optional(bool, false)
  })
}

variable "oauth" {
  sensitive = true
  type = object({
    client_id          = string
    client_secret      = string
    trusted_client_ids = string
    service_client_ids = string
  })
}

variable "service" {
  type = object({
    node_env         = optional(string, "production")
    signal_db_name   = optional(string, "apollo_deploy_signal")
    billing_base_url = optional(string, "http://apollo-billing:3040")
    signal_base_url  = optional(string, "")
    metrics_enabled  = optional(bool, false)
  })
}

variable "nginx" {
  type = object({
    image      = optional(string, "nginx:1.27.5-alpine@sha256:65645c7bb6a0661892a8b03b89d0743208a18dd2f3f17a54ef4b76fb8e2f2a10")
    conf_dir   = string
    http_port  = optional(number, 80)
    https_port = optional(number, 443)
    bind_ip    = optional(string, "0.0.0.0")
  })

  validation {
    condition     = can(regex("@sha256:[0-9a-f]{64}$", var.nginx.image))
    error_message = "nginx.image must be pinned by a lowercase sha256 manifest digest."
  }
}

variable "dev_mode" {
  type    = bool
  default = false
}

variable "source_dir" {
  type    = string
  default = ""
}
