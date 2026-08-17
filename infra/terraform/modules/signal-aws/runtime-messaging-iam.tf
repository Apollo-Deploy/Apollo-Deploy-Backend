data "aws_iam_policy_document" "runtime_messaging" {
  statement {
    sid = "UseSignalQueues"
    actions = [
      "sqs:ChangeMessageVisibility",
      "sqs:DeleteMessage",
      "sqs:GetQueueAttributes",
      "sqs:GetQueueUrl",
      "sqs:ReceiveMessage",
      "sqs:SendMessage",
    ]
    resources = values(module.message_queues.queue_arns)
  }

  statement {
    sid       = "PublishSignalTopics"
    actions   = ["sns:Publish"]
    resources = local.application_topic_arns
  }

  statement {
    sid = "UseSignalMessagingKey"
    actions = [
      "kms:Decrypt",
      "kms:DescribeKey",
      "kms:GenerateDataKey*",
    ]
    resources = concat(
      [module.messaging_encryption.key_arn],
      [for regional in values(module.additional_messaging_encryption) : regional.key_arn],
    )
  }

  # GetAccount has no resource type in the SES v2 authorization reference.
  # It is the only wildcard SES permission and is read-only.
}
