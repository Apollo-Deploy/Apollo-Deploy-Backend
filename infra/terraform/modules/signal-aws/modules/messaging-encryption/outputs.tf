output "key_arn" {
  description = "KMS key ARN protecting Signal SNS and private-ingestion data."
  value       = aws_kms_key.messaging.arn
}

output "topic_arns" {
  description = "Exact Signal SNS topic ARNs authorized by the KMS policy."
  value = {
    managed_event = local.managed_event_topic_arn
    dmarc_inbound = local.dmarc_inbound_topic_arn
  }
}
