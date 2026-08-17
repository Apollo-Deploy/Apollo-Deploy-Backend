output "access_key_id" {
  description = "Access key ID used by the Signal runtime IAM user."
  value       = aws_iam_access_key.signal.id
  sensitive   = true
}

output "secret_access_key" {
  description = "Secret access key used by the Signal runtime IAM user."
  value       = aws_iam_access_key.signal.secret
  sensitive   = true
}

output "account_id" {
  description = "AWS account ID in which Signal resources are managed."
  value       = data.aws_caller_identity.current.account_id
}

output "queue_urls" {
  description = "Stable Signal queue URLs; routing flags never destroy retained work."
  value = {
    scheduled_email = module.message_queues.queue_urls["scheduled-email"]
    dmarc_inbound   = module.message_queues.queue_urls["dmarc-reports"]
  }
}

output "bucket_names" {
  description = "Names of the durable Signal media, ingestion, and project-archive buckets."
  value = {
    contact_images   = module.media_storage.bucket_ids["contact-images"]
    template_media   = module.media_storage.bucket_ids["template-media"]
    dmarc_inbound    = module.media_storage.bucket_ids["dmarc-reports"]
    project_archives = module.project_archives.bucket_id
  }
}

output "project_archive_bucket_arn" {
  description = "Private, versioned and Object-Locked S3 bucket ARN used for Signal project deletion archives."
  value       = module.project_archives.bucket_arn
}

output "project_archive_kms_key_arn" {
  description = "Customer-managed KMS key ARN used for Signal project archive SSE-KMS."
  value       = module.project_archives.kms_key_arn
}

output "support_restore_role_arn" {
  description = "Dedicated role with read/decrypt-only access to Signal project archives."
  value       = module.project_archives.support_restore_role_arn
}

output "dmarc_inbound_topic_arn" {
  description = "Durable DMARC-ingestion SNS topic ARN."
  value       = module.dmarc_ingestion.topic_arn
}

output "configuration_set_name" {
  description = "Managed SES configuration-set name used for Signal delivery feedback."
  value       = module.ses_feedback.configuration_set_name
}

output "managed_event_topic_arn" {
  description = "Managed SNS topic ARN carrying Signal SES delivery events."
  value       = module.ses_feedback.event_topic_arn
}

output "additional_event_topic_arns" {
  description = "Managed SES feedback topic ARNs keyed by each additional Signal service region."
  value       = { for region, feedback in module.additional_ses_feedback : region => feedback.event_topic_arn }
}

output "event_topic_arns" {
  description = "Managed SES feedback topic ARNs keyed by every selected Signal service region."
  value = merge(
    { (var.region) = module.ses_feedback.event_topic_arn },
    { for region, feedback in module.additional_ses_feedback : region => feedback.event_topic_arn },
  )
}
