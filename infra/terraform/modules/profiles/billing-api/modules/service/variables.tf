variable "network_name" { type = string }
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

variable "db" {
  sensitive = true
  type = object({
    host               = optional(string, "apollo-platform-postgres")
    port               = optional(number, 5432)
    name               = optional(string, "apollo_deploy_platform")
    user               = optional(string, "billing_app")
    password           = string
    superuser_password = string
  })
}

variable "signal_db" {
  default = {}
  type = object({
    host = optional(string, "apollo-platform-postgres")
    port = optional(number, 5432)
    name = optional(string, "apollo_deploy_signal")
  })
}

variable "redis" {
  sensitive = true
  type = object({
    host     = optional(string, "apollo-platform-redis")
    port     = optional(number, 6379)
    password = string
  })
}

variable "oauth" {
  sensitive = true
  type = object({
    platform_url          = string
    platform_audience_url = string
    client_id             = string
    client_secret         = string
    issuer_url            = optional(string, "")
    valid_audiences       = optional(string, "")
    jwks_url              = optional(string, "http://apollo-platform:3000/auth/jwks")
    service_client_ids    = optional(string, "")
  })
}

variable "polar" {
  sensitive = true
  default   = {}
  type = object({
    api_key        = optional(string, "")
    webhook_secret = optional(string, "")
    base_url       = optional(string, "https://api.polar.sh")
  })
}

variable "dev_mode" {
  type    = bool
  default = false
}

variable "source_dir" {
  type    = string
  default = ""
}
