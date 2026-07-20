variable "network_name" {
  type        = string
  description = "Shared Docker network name"
}

variable "image" {
  type        = string
  description = "Signal API Docker image reference (registry ref) or locally built image ID"
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
  description = "Signal database connection"
  type = object({
    host     = optional(string, "apollo-platform-postgres")
    port     = optional(number, 5432)
    name     = optional(string, "apollo_deploy_signal")
    user     = optional(string, "signal_app")
    password = string
    sslmode  = optional(string, "disable")
  })
  sensitive = true
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
  description = "OAuth / platform connection and session configuration"
  type = object({
    platform_internal_url   = optional(string, "http://apollo-platform:3000")
    platform_audience_url   = string
    client_id               = string
    client_secret           = string
    issuer_url              = string
    valid_audiences         = string
    internal_service_secret = string
    session_secret          = string
    secure_cookies          = optional(bool, true)
    cors_origins            = optional(string, "")
  })
  sensitive = true
}

variable "aws" {
  description = "AWS credentials and service endpoints"
  type = object({
    region            = optional(string, "us-east-1")
    access_key_id     = optional(string, "")
    secret_access_key = optional(string, "")
    account_id        = optional(string, "")
    ses_config_set    = optional(string, "apollo-signal")
    sqs_webhook_url   = optional(string, "")
    sqs_scheduled_url = optional(string, "")
    sqs_domain_url    = optional(string, "")
  })
  sensitive = true
  default   = {}
}

variable "storage" {
  description = "Object storage configuration (R2 or S3)"
  type = object({
    provider         = optional(string, "r2")
    bucket           = optional(string, "")
    public_base_url  = optional(string, "")
    r2_account_id    = optional(string, "")
    r2_access_key_id = optional(string, "")
    r2_secret_key    = optional(string, "")
  })
  sensitive = true
  default   = {}
}

variable "features" {
  description = "Optional feature flags and integration secrets"
  type = object({
    events_signing_secret = optional(string, "")
    webhook_secret_key    = optional(string, "")
    byok_secret_key       = optional(string, "")
    byok_cfn_template_url = optional(string, "")
    tracking_base_url     = optional(string, "")
    tracking_cname_target = optional(string, "")
    koog_api_key          = optional(string, "")
    koog_model            = optional(string, "deepseek-v4")
    billing_base_url      = optional(string, "http://apollo-billing:3040")
  })
  sensitive = true
  default   = {}
}

variable "sms" {
  description = "SMS provider credentials"
  type = object({
    telnyx_api_key              = optional(string, "")
    telnyx_messaging_profile_id = optional(string, "")
  })
  sensitive = true
  default   = {}
}

variable "geoip_host_path" {
  type        = string
  description = "Host path containing the dbip-city-lite.mmdb GeoIP database file"
}

variable "dev_mode" {
  type    = bool
  default = false
}

variable "source_dir" {
  type    = string
  default = ""
}
