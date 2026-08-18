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
    host     = optional(string, "apollo-platform-postgres")
    port     = optional(number, 5432)
    name     = optional(string, "apollo_deploy_signal")
    user     = optional(string, "signal_app")
    password = string
    sslmode  = optional(string, "disable")
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
    platform_internal_url   = optional(string, "http://apollo-platform:3000")
    auth_jwks_url           = optional(string, "")
    platform_audience_url   = string
    client_id               = string
    client_secret           = string
    issuer_url              = string
    valid_audiences         = string
    internal_service_secret = string
    session_secret          = string
    secure_cookies          = optional(bool, true)
    cors_origins            = optional(string, "")
    service_client_ids      = string
  })
}

variable "aws" {
  sensitive = true
  default   = {}
  type = object({
    region                          = optional(string, "af-south-1")
    extra_regions                   = optional(set(string), [])
    access_key_id                   = optional(string, "")
    secret_access_key               = optional(string, "")
    account_id                      = optional(string, "")
    ses_config_set                  = optional(string, "apollo-signal")
    sqs_scheduled_email_url         = optional(string, "")
    sqs_dmarc_inbound_url           = optional(string, "")
    sns_event_topic_arn             = optional(string, "")
    sns_event_topic_arns            = optional(set(string), [])
    sns_dmarc_inbound_topic_arn     = optional(string, "")
    s3_contact_images_bucket        = optional(string, "")
    s3_dmarc_inbound_bucket         = optional(string, "")
    dmarc_ingestion_enabled         = optional(bool, false)
    s3_project_archives_bucket      = optional(string, "")
    s3_project_archives_kms_key_arn = optional(string, "")
  })

  validation {
    condition = var.aws.s3_project_archives_bucket == "" || try(
      can(regex(
        "^arn:[a-z0-9-]+:kms:[a-z0-9-]+:[0-9]{12}:key/[0-9a-fA-F-]{36}$",
        var.aws.s3_project_archives_kms_key_arn,
      )) &&
      split(":", var.aws.s3_project_archives_kms_key_arn)[3] == var.aws.region &&
      split(":", var.aws.s3_project_archives_kms_key_arn)[4] == var.aws.account_id,
      false,
    )
    error_message = "Project archive storage requires an exact customer-managed KMS key ARN in the configured AWS account and region."
  }
}

variable "storage" {
  sensitive = true
  type = object({
    bucket          = string
    public_base_url = optional(string, "")
  })
}

variable "features" {
  sensitive = true
  default   = {}
  type = object({
    events_signing_secret  = optional(string, "")
    webhook_secret_key     = optional(string, "")
    import_credentials_key = optional(string, "")
    tracking_base_url      = optional(string, "")
    koog_api_key           = optional(string, "")
    koog_model             = optional(string, "deepseek-v4")
    billing_base_url       = optional(string, "http://apollo-billing:3040")
  })
}

variable "geoip_host_path" { type = string }

variable "dev_mode" {
  type    = bool
  default = false
}

variable "source_dir" {
  type    = string
  default = ""
}
