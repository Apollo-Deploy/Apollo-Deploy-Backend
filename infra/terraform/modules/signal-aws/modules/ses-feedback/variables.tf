variable "partition" {
  description = "AWS partition used to build service and account ARNs."
  type        = string
}

variable "account_id" {
  description = "AWS account ID owning the SES and SNS resources."
  type        = string
}

variable "region" {
  description = "AWS region containing the SES configuration set and SNS topic."
  type        = string
}

variable "configuration_set_name" {
  description = "Shared Signal SES configuration-set name."
  type        = string
}

variable "event_topic_name" {
  description = "SNS topic name receiving managed SES delivery events."
  type        = string
}

variable "messaging_kms_key_arn" {
  description = "KMS key ARN protecting the SES feedback topic."
  type        = string
}

variable "tags" {
  description = "Tags applied to SES feedback resources."
  type        = map(string)
  default     = {}
}
