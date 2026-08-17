# A customer-managed key protects private ingestion objects and every Signal SNS
# topic. Account administration remains with the owning account, while the
# runtime user and SES receive only the cryptographic operations they require.
locals {
  managed_event_topic_arn = "arn:${var.partition}:sns:${var.region}:${var.account_id}:${var.managed_event_topic_name}"
  dmarc_inbound_topic_arn = "arn:${var.partition}:sns:${var.region}:${var.account_id}:${var.name_prefix}-dmarc-inbound"

  # Derive these ARNs from stable inputs instead of aws_sns_topic attributes:
  # every topic references this key, so resource references here would create a
  # KMS key <-> SNS topic dependency cycle.
  messaging_topic_arns = concat(
    [local.managed_event_topic_arn],
    var.enable_dmarc_ingestion ? [local.dmarc_inbound_topic_arn] : [],
  )

  sns_kms_policy_contract = {
    principal                    = "sns.amazonaws.com"
    source_arn_condition_key     = "aws:SourceArn"
    encryption_context_key       = "kms:EncryptionContext:aws:sns:topicArn"
    source_account_condition_key = "aws:SourceAccount"
  }

  local_ses_messaging_source_arns = concat(
    [
      "arn:${var.partition}:ses:${var.region}:${var.account_id}:configuration-set/${var.configuration_set_name}",
    ],
    var.enable_dmarc_ingestion ? [
      "arn:${var.partition}:ses:${var.region}:${var.account_id}:receipt-rule-set/${var.dmarc_receipt_rule_set_name}:receipt-rule/store-dmarc-reports",
    ] : [],
  )

}

data "aws_iam_policy_document" "messaging_key" {
  statement {
    sid       = "EnableAccountAdministration"
    actions   = ["kms:*"]
    resources = ["*"]

    principals {
      type        = "AWS"
      identifiers = ["arn:${var.partition}:iam::${var.account_id}:root"]
    }
  }

  statement {
    sid = "AllowSignalRuntimeUse"
    actions = [
      "kms:Decrypt",
      "kms:DescribeKey",
      "kms:GenerateDataKey*",
    ]
    resources = ["*"]

    principals {
      type        = "AWS"
      identifiers = [var.runtime_user_arn]
    }
  }

  # SNS performs the topic encryption operations. Both the calling resource
  # ARN and SNS encryption context must identify one of this module's exact,
  # active topics; the input-derived ARNs avoid a resource dependency cycle.
  statement {
    sid = "AllowSignalSnsUse"
    actions = [
      "kms:Decrypt",
      "kms:GenerateDataKey*",
    ]
    resources = ["*"]

    principals {
      type        = "Service"
      identifiers = [local.sns_kms_policy_contract.principal]
    }

    condition {
      test     = "StringEquals"
      variable = local.sns_kms_policy_contract.source_account_condition_key
      values   = [var.account_id]
    }

    condition {
      test     = "ArnEquals"
      variable = local.sns_kms_policy_contract.source_arn_condition_key
      values   = local.messaging_topic_arns
    }

    condition {
      test     = "StringEquals"
      variable = local.sns_kms_policy_contract.encryption_context_key
      values   = local.messaging_topic_arns
    }
  }

  # SES must use the key when it publishes encrypted SNS messages or writes to
  # an SSE-KMS ingestion bucket. Source-account and source-ARN conditions keep
  # the regional service principal from becoming a confused deputy.
  statement {
    sid = "AllowLocalSESUse"
    actions = [
      "kms:Decrypt",
      "kms:GenerateDataKey*",
    ]
    resources = ["*"]

    principals {
      type        = "Service"
      identifiers = ["ses.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "AWS:SourceAccount"
      values   = [var.account_id]
    }

    condition {
      test     = "ArnLike"
      variable = "AWS:SourceArn"
      values   = local.local_ses_messaging_source_arns
    }
  }

}

resource "aws_kms_key" "messaging" {
  description             = "Signal SNS and private ingestion encryption"
  enable_key_rotation     = true
  deletion_window_in_days = 30
  policy                  = data.aws_iam_policy_document.messaging_key.json

  tags = merge(var.tags, {
    service    = "signal"
    data_class = "messaging-encryption"
  })

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_kms_alias" "messaging" {
  name          = "alias/${var.name_prefix}-signal-messaging"
  target_key_id = aws_kms_key.messaging.key_id
}
