variable "name_prefix" {
  description = "Stable prefix for Signal project-archive resources."
  type        = string
}

variable "bucket_name_prefix" {
  description = "Stable namespace prefix for the Signal project-archives bucket."
  type        = string
}

variable "region" {
  description = "AWS region containing the archive resources."
  type        = string
}

variable "bucket_name_overrides" {
  description = "Optional bucket name override keyed by project-archives."
  type        = map(string)
  default     = {}
}

variable "archive_retention_days" {
  description = "S3 Object Lock and lifecycle retention for project archives."
  type        = number
}

variable "runtime_user_arn" {
  description = "Signal runtime IAM user ARN denied archive deletion and retention mutation."
  type        = string
}

variable "support_restore_trusted_principal_arns" {
  description = "IAM principals allowed to assume the archive restore role."
  type        = set(string)
  default     = []
}

variable "tags" {
  description = "Tags applied to project-archive resources."
  type        = map(string)
  default     = {}
}
