variable "environment" {
  description = "Deployment environment name used in resource names and tags."
  type        = string
  default     = "production"
}

variable "base_domain" {
  description = "Apollo production base domain."
  type        = string
  validation {
    condition     = can(regex("^(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?[.])+(?:[A-Za-z]{2,63})$", var.base_domain))
    error_message = "base_domain must be a fully qualified DNS name."
  }
}

variable "api_hosts" {
  description = "Canonical public API hostnames."
  type = object({
    platform = string
    signal   = string
    billing  = string
  })
  validation {
    condition = alltrue([
      for hostname in values(var.api_hosts) : can(regex("^[A-Za-z0-9.-]+$", hostname))
    ])
    error_message = "Every API hostname must be a DNS hostname without a scheme or path."
  }
}

variable "cloudflare" {
  description = "Cloudflare DNS ownership and VPS origin. Authentication uses CLOUDFLARE_API_TOKEN."
  type = object({
    zone_id     = string
    origin_ipv4 = string
    proxied     = bool
  })
  validation {
    condition     = can(cidrhost("${var.cloudflare.origin_ipv4}/32", 0))
    error_message = "cloudflare.origin_ipv4 must be an IPv4 address."
  }
}

variable "aws" {
  description = "Signal AWS account, region, durable resource and operator-alert settings."
  type = object({
    account_id                             = string
    region                                 = string
    operator_alert_topic_arn               = string
    archive_retention_days                 = optional(number, 2555)
    bucket_name_overrides                  = optional(map(string), {})
    support_restore_trusted_principal_arns = optional(set(string), [])
  })
  validation {
    condition     = can(regex("^[0-9]{12}$", var.aws.account_id))
    error_message = "aws.account_id must be a 12-digit account ID."
  }
}

variable "signal" {
  description = "Signal regional and DMARC external-infrastructure settings."
  type = object({
    supported_regions           = set(string)
    enable_dmarc_ingestion      = optional(bool, false)
    dmarc_receipt_rule_set_name = optional(string, "")
  })
  validation {
    condition     = contains(var.signal.supported_regions, var.aws.region)
    error_message = "signal.supported_regions must include aws.region."
  }
}

variable "enable_ses_feedback_subscription" {
  description = "Enable HTTPS subscriptions only after the Signal endpoint has valid TLS and is healthy."
  type        = bool
  default     = true
}
