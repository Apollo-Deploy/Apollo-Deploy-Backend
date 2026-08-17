resource "aws_sqs_queue" "dlq" {
  for_each = var.queues

  region                    = var.region
  name                      = "${var.name_prefix}-${each.key}-dlq"
  message_retention_seconds = 1209600
  sqs_managed_sse_enabled   = true
}

resource "aws_sqs_queue" "this" {
  for_each = var.queues

  region                     = var.region
  name                       = "${var.name_prefix}-${each.key}"
  visibility_timeout_seconds = each.value.visibility_timeout_seconds
  message_retention_seconds  = each.value.message_retention_seconds
  sqs_managed_sse_enabled    = true
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq[each.key].arn
    maxReceiveCount     = 5
  })
}

resource "aws_sqs_queue_redrive_allow_policy" "dlq" {
  for_each = var.queues

  region    = var.region
  queue_url = aws_sqs_queue.dlq[each.key].id
  redrive_allow_policy = jsonencode({
    redrivePermission = "byQueue"
    sourceQueueArns   = [aws_sqs_queue.this[each.key].arn]
  })
}

resource "aws_cloudwatch_metric_alarm" "dlq_visible_messages" {
  for_each = var.queues

  region              = var.region
  alarm_name          = "${var.name_prefix}-${each.key}-dlq-visible"
  alarm_description   = "Signal ${each.key} messages reached the DLQ and require operator recovery."
  namespace           = "AWS/SQS"
  metric_name         = "ApproximateNumberOfMessagesVisible"
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 1
  datapoints_to_alarm = 1
  comparison_operator = "GreaterThanThreshold"
  threshold           = 0
  treat_missing_data  = "notBreaching"
  alarm_actions       = [var.operator_alert_topic_arn]
  ok_actions          = [var.operator_alert_topic_arn]

  dimensions = {
    QueueName = aws_sqs_queue.dlq[each.key].name
  }
}

resource "aws_cloudwatch_metric_alarm" "source_oldest_message" {
  for_each = var.queues

  region              = var.region
  alarm_name          = "${var.name_prefix}-${each.key}-oldest-message"
  alarm_description   = "Signal ${each.key} processing age exceeded its operational threshold."
  namespace           = "AWS/SQS"
  metric_name         = "ApproximateAgeOfOldestMessage"
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 2
  datapoints_to_alarm = 2
  comparison_operator = "GreaterThanThreshold"
  threshold           = each.value.oldest_message_alarm_seconds
  treat_missing_data  = "notBreaching"
  alarm_actions       = [var.operator_alert_topic_arn]
  ok_actions          = [var.operator_alert_topic_arn]

  dimensions = {
    QueueName = aws_sqs_queue.this[each.key].name
  }
}
