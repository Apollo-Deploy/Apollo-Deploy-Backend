output "topic_arn" {
  description = "Durable SNS topic ARN carrying DMARC ingestion notifications."
  value       = aws_sns_topic.dmarc.arn
}
