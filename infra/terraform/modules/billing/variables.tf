variable "network_name" {
  type        = string
  description = "Shared Docker network name"
}

variable "image" {
  type        = string
  description = "Billing API Docker image reference (registry ref) or locally built image ID"
}

variable "image_pull_trigger" {
  type        = string
  default     = ""
  description = <<-DESC
    Upstream image digest used as a pull trigger. Pass the sha256_digest from a
    docker_registry_image data source when `image` is a registry reference so a
    moving tag is re-pulled on apply. Leave empty for locally built images.
  DESC
}

variable "db" {
  description = "Primary database connection (billing_app role)"
  type = object({
    host               = optional(string, "apollo-platform-postgres")
    port               = optional(number, 5432)
    name               = optional(string, "apollo_deploy_platform")
    user               = optional(string, "billing_app")
    password           = string
    superuser_password = string
  })
  sensitive = true
}

variable "signal_db" {
  description = "Signal database reference (read-only via billing_superuser)"
  type = object({
    host = optional(string, "apollo-platform-postgres")
    port = optional(number, 5432)
    name = optional(string, "apollo_deploy_signal")
  })
  default = {}
}

variable "redis" {
  description = "Redis connection"
  type = object({
    host     = optional(string, "apollo-platform-redis")
    port     = optional(number, 6379)
    password = string
  })
  sensitive = true
}

variable "oauth" {
  description = "OAuth / platform connection"
  type = object({
    platform_url       = string
    client_id          = string
    client_secret      = string
    issuer_url         = optional(string, "")
    valid_audiences    = optional(string, "")
    service_client_ids = optional(string, "")
  })
  sensitive = true
}

variable "polar" {
  description = "Polar.sh billing integration"
  type = object({
    api_key        = optional(string, "")
    webhook_secret = optional(string, "")
    base_url       = optional(string, "https://api.polar.sh")
  })
  sensitive = true
  default   = {}
}

variable "dev_mode" {
  type    = bool
  default = false
}

variable "source_dir" {
  type    = string
  default = ""
}
