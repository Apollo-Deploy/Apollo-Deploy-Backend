output "deployment_inputs" {
  description = "Nonsecret AWS values consumed by the production VPS setup flow."
  value = {
    account_id               = data.aws_caller_identity.current.account_id
    region                   = var.region
    state_bucket             = aws_s3_bucket.terraform_state.id
    state_kms_key_arn        = aws_kms_key.terraform_state.arn
    operator_alert_topic_arn = aws_sns_topic.operator_alerts.arn
  }
}
