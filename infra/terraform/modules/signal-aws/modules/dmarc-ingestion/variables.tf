variable "name_prefix" {
  description = "Stable prefix for DMARC ingestion resources."
  type        = string
}

variable "partition" {
  description = "AWS partition used to build account ARNs."
  type        = string
}

variable "account_id" {
  description = "AWS account ID owning DMARC resources."
  type        = string
}

variable "region" {
  description = "AWS region containing DMARC resources."
  type        = string
}

variable "enabled" {
  description = "Whether SES receipt routing to the durable DMARC storage and queue is active."
  type        = bool
}

variable "receipt_rule_set_name" {
  description = "Existing SES receipt rule set used when DMARC routing is active."
  type        = string
  default     = null
  nullable    = true
}

variable "reports_domain" {
  description = "Domain receiving generated DMARC RUA messages."
  type        = string
}

variable "current_retention_days" {
  description = "Retention for current raw DMARC objects."
  type        = number
}

variable "noncurrent_retention_days" {
  description = "Retention for noncurrent raw DMARC objects."
  type        = number
}

variable "bucket_id" {
  description = "Durable DMARC ingestion bucket ID."
  type        = string
}

variable "bucket_arn" {
  description = "Durable DMARC ingestion bucket ARN."
  type        = string
}

variable "queue_url" {
  description = "Durable DMARC processing queue URL."
  type        = string
}

variable "queue_arn" {
  description = "Durable DMARC processing queue ARN."
  type        = string
}

variable "messaging_kms_key_arn" {
  description = "KMS key ARN protecting the DMARC SNS topic."
  type        = string
}
