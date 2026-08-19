variable "name_prefix" {
  description = "Stable prefix for Signal-owned AWS resources."
  type        = string
}

variable "bucket_name_prefix" {
  description = "Globally unique namespace prefix used only for Signal S3 buckets."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{1,39}[a-z0-9]$", var.bucket_name_prefix))
    error_message = "bucket_name_prefix must be a lowercase 3-41 character S3-compatible prefix."
  }
}

variable "region" {
  description = "Primary AWS region containing Signal's durable storage, queues, and ingestion resources."
  type        = string
}

variable "additional_service_regions" {
  description = "Additional AWS regions in which Signal may manage SES domains and dedicated-IP resources."
  type        = set(string)
  default     = []

  validation {
    condition = (
      !contains(var.additional_service_regions, var.region) &&
      alltrue([for region in var.additional_service_regions : can(regex("^[a-z]{2}(-[a-z]+)+-[0-9]+$", region))])
    )
    error_message = "additional_service_regions must exclude region and contain only valid AWS region identifiers."
  }
}

variable "template_media_allowed_origins" {
  description = "HTTPS browser origins permitted to PUT template media with Signal-issued presigned URLs."
  type        = set(string)

  validation {
    condition     = length(var.template_media_allowed_origins) > 0 && alltrue([for origin in var.template_media_allowed_origins : can(regex("^https://[^[:space:]]+$", origin))])
    error_message = "template_media_allowed_origins must contain one or more HTTPS origins."
  }
}

variable "configuration_set_name" {
  description = "Shared SES configuration-set name used for Signal delivery and feedback."
  type        = string
  default     = "apollo-signal"

  validation {
    condition = (
      can(regex("^[A-Za-z0-9_-]{1,64}$", var.configuration_set_name)) &&
      !startswith(var.configuration_set_name, "signal-dip-cfg-")
    )
    error_message = "configuration_set_name must be a literal SES name outside the reserved signal-dip-cfg-* runtime prefix."
  }
}

variable "managed_event_topic_name" {
  description = "SNS topic name receiving managed SES delivery events."
  type        = string
  default     = "apollo-signal-ses-events"
}

variable "bucket_name_overrides" {
  description = "Optional primary-region bucket names keyed by contact-images, template-media, dmarc-reports, or project-archives."
  type        = map(string)
  default     = {}
}

variable "archive_retention_days" {
  description = "Minimum S3 Object Lock and lifecycle retention for Signal project archives."
  type        = number
  default     = 90

  validation {
    condition     = var.archive_retention_days == 90
    error_message = "archive_retention_days must remain 90 days."
  }
}

variable "support_restore_trusted_principal_arns" {
  description = "Named IAM principals allowed to assume the dedicated read-only Signal project archive restore role."
  type        = set(string)
  default     = []

  validation {
    condition     = alltrue([for arn in var.support_restore_trusted_principal_arns : can(regex("^arn:[^:]+:iam::[0-9]{12}:.+$", arn))])
    error_message = "support_restore_trusted_principal_arns must contain only IAM principal ARNs."
  }
}

variable "operator_alert_topic_arn" {
  description = "Existing operator-owned SNS topic ARN that receives every Signal queue alarm."
  type        = string

  validation {
    condition     = can(regex("^arn:[a-z0-9-]+:sns:[a-z0-9-]+:[0-9]{12}:[A-Za-z0-9_-]{1,256}$", var.operator_alert_topic_arn))
    error_message = "operator_alert_topic_arn must be an exact SNS topic ARN."
  }
}

variable "dmarc_receipt_rule_set_name" {
  description = "Existing regional SES receipt rule set in which to create the core DMARC receipt rule."
  type        = string
  nullable    = false

  validation {
    condition     = length(trimspace(var.dmarc_receipt_rule_set_name)) > 0
    error_message = "dmarc_receipt_rule_set_name must name an existing SES receipt rule set."
  }
}

variable "dmarc_reports_domain" {
  description = "Domain that receives generated DMARC RUA addresses."
  type        = string
  default     = "reports.apollodeploy.com"
}

variable "dmarc_current_retention_days" {
  description = "Retention in days for current raw DMARC report objects."
  type        = number
  default     = 30
}

variable "dmarc_noncurrent_retention_days" {
  description = "Retention in days for noncurrent raw DMARC report objects."
  type        = number
  # SES creates unique message-id keys. Current expiration first creates a
  # delete marker; removing the resulting noncurrent bytes shortly afterward
  # keeps versioning from silently extending raw retention by another month.
  default = 1
}

variable "tags" {
  description = "Tags applied to Signal-owned AWS resources."
  type        = map(string)
  default     = {}
}
