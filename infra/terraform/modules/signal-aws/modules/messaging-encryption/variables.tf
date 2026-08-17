variable "name_prefix" {
  description = "Stable prefix for the Signal messaging KMS alias."
  type        = string
}

variable "partition" {
  description = "AWS partition used to build policy ARNs."
  type        = string
}

variable "account_id" {
  description = "AWS account ID owning the encrypted messaging resources."
  type        = string
}

variable "region" {
  description = "AWS region containing encrypted messaging resources."
  type        = string
}

variable "runtime_user_arn" {
  description = "Signal runtime IAM user ARN granted cryptographic data-plane operations."
  type        = string
}

variable "managed_event_topic_name" {
  description = "Managed SES feedback SNS topic name."
  type        = string
}

variable "configuration_set_name" {
  description = "Shared Signal SES configuration-set name."
  type        = string
}

variable "enable_dmarc_ingestion" {
  description = "Whether the regional SES DMARC receipt rule may use this key."
  type        = bool
}

variable "dmarc_receipt_rule_set_name" {
  description = "Existing SES receipt rule set used when DMARC ingestion is active."
  type        = string
  default     = null
  nullable    = true
}

variable "tags" {
  description = "Tags applied to the messaging KMS key."
  type        = map(string)
  default     = {}
}
