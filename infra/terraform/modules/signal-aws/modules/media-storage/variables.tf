variable "bucket_name_prefix" {
  description = "Stable namespace prefix for Signal media and ingestion buckets."
  type        = string
}

variable "region" {
  description = "AWS region containing the buckets."
  type        = string
}

variable "bucket_name_overrides" {
  description = "Optional bucket names keyed by contact-images, template-media, or dmarc-reports."
  type        = map(string)
  default     = {}
}

variable "template_media_allowed_origins" {
  description = "HTTPS browser origins permitted to use Signal template-media presigned URLs."
  type        = set(string)
}

variable "messaging_kms_key_arn" {
  description = "KMS key ARN protecting private ingestion objects."
  type        = string
}

variable "tags" {
  description = "Tags applied to Signal storage resources."
  type        = map(string)
  default     = {}
}
