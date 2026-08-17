data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  service_regions = setunion(toset([var.region]), var.additional_service_regions)

  queues = {
    scheduled-email = {
      visibility_timeout_seconds   = 60
      message_retention_seconds    = 345600
      oldest_message_alarm_seconds = 300
    }
    dmarc-reports = {
      # Longer than the Signal processor's ten-minute lease so a healthy
      # parse cannot be delivered concurrently to another replica.
      visibility_timeout_seconds   = 900
      message_retention_seconds    = 1209600
      oldest_message_alarm_seconds = 1200
    }
  }

  application_topic_arns = concat(
    [module.ses_feedback.event_topic_arn],
    [for feedback in values(module.additional_ses_feedback) : feedback.event_topic_arn],
    var.enable_dmarc_ingestion ? [module.dmarc_ingestion.topic_arn] : [],
  )

}
