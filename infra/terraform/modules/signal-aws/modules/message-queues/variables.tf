variable "name_prefix" {
  description = "Stable prefix for Signal queues and alarms."
  type        = string
}

variable "region" {
  description = "AWS region containing the queues."
  type        = string
}

variable "queues" {
  description = "Stable Signal queue definitions keyed by workload."
  type = map(object({
    visibility_timeout_seconds   = number
    message_retention_seconds    = number
    oldest_message_alarm_seconds = number
  }))
}

variable "operator_alert_topic_arn" {
  description = "Operator-owned SNS topic ARN receiving queue alarm transitions."
  type        = string
}
