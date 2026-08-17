output "configuration_set_name" {
  description = "Managed Signal SES configuration-set name."
  value       = aws_sesv2_configuration_set.signal.configuration_set_name
}

output "event_topic_arn" {
  description = "SNS topic ARN carrying managed SES delivery events."
  value       = aws_sns_topic.event.arn
}
