# SES receipt rules are regional and accept mail only for an identity that is
# already configured in that region. This lookup makes a missing identity fail
# during planning before Terraform attempts to create the DMARC rule.
data "aws_sesv2_email_identity" "dmarc_receiving" {
  region         = var.region
  email_identity = var.reports_domain
}

locals {
  s3_tls_only_policy = {
    sid                   = "DenyInsecureTransport"
    actions               = ["s3:*"]
    principal_type        = "*"
    principal_identifiers = ["*"]
    secure_transport = {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
    non_service_principal = {
      test     = "Bool"
      variable = "aws:PrincipalIsAWSService"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "dmarc" {
  # Retain the existing [0] address used by the original optional deployment.
  count  = 1
  bucket = var.bucket_id
  region = var.region

  rule {
    id     = "expire-dmarc-raw-mime"
    status = "Enabled"

    filter {
      prefix = "raw/v1/"
    }

    expiration {
      days = var.current_retention_days
    }

    noncurrent_version_expiration {
      noncurrent_days = var.noncurrent_retention_days
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }

  rule {
    id     = "remove-expired-dmarc-delete-markers"
    status = "Enabled"

    filter {
      prefix = "raw/v1/"
    }

    expiration {
      expired_object_delete_marker = true
    }
  }

}

data "aws_iam_policy_document" "dmarc_bucket" {
  # Retain the existing [0] address used by the original optional deployment.
  count = 1

  statement {
    sid       = "AllowSESDmarcDelivery"
    actions   = ["s3:PutObject"]
    resources = ["${var.bucket_arn}/raw/v1/*"]

    principals {
      type        = "Service"
      identifiers = ["ses.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "AWS:SourceAccount"
      values   = [var.account_id]
    }
  }

  statement {
    sid     = local.s3_tls_only_policy.sid
    effect  = "Deny"
    actions = local.s3_tls_only_policy.actions
    resources = [
      var.bucket_arn,
      "${var.bucket_arn}/*",
    ]

    principals {
      type        = local.s3_tls_only_policy.principal_type
      identifiers = local.s3_tls_only_policy.principal_identifiers
    }

    condition {
      test     = local.s3_tls_only_policy.secure_transport.test
      variable = local.s3_tls_only_policy.secure_transport.variable
      values   = local.s3_tls_only_policy.secure_transport.values
    }

    condition {
      test     = local.s3_tls_only_policy.non_service_principal.test
      variable = local.s3_tls_only_policy.non_service_principal.variable
      values   = local.s3_tls_only_policy.non_service_principal.values
    }
  }
}

resource "aws_s3_bucket_policy" "dmarc" {
  count  = 1
  bucket = var.bucket_id
  region = var.region
  policy = data.aws_iam_policy_document.dmarc_bucket[0].json
}

resource "aws_sns_topic" "dmarc" {
  region            = var.region
  name              = "${var.name_prefix}-dmarc-inbound"
  kms_master_key_id = var.messaging_kms_key_arn
}

data "aws_iam_policy_document" "dmarc_topic" {
  statement {
    sid    = "OwnerAdministration"
    effect = "Allow"
    actions = [
      "SNS:DeleteTopic",
      "SNS:GetTopicAttributes",
      "SNS:ListSubscriptionsByTopic",
      "SNS:Publish",
      "SNS:SetTopicAttributes",
      "SNS:Subscribe",
    ]
    resources = [aws_sns_topic.dmarc.arn]

    principals {
      type        = "AWS"
      identifiers = ["arn:${var.partition}:iam::${var.account_id}:root"]
    }
  }

  statement {
    sid       = "AllowSESDmarcNotification"
    effect    = "Allow"
    actions   = ["SNS:Publish"]
    resources = [aws_sns_topic.dmarc.arn]

    principals {
      type        = "Service"
      identifiers = ["ses.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "AWS:SourceAccount"
      values   = [var.account_id]
    }
  }
}

resource "aws_sns_topic_policy" "dmarc" {
  region = var.region
  arn    = aws_sns_topic.dmarc.arn
  policy = data.aws_iam_policy_document.dmarc_topic.json
}

data "aws_iam_policy_document" "dmarc_queue" {
  count = 1

  statement {
    sid       = "AllowDmarcTopic"
    actions   = ["sqs:SendMessage"]
    resources = [var.queue_arn]

    principals {
      type        = "Service"
      identifiers = ["sns.amazonaws.com"]
    }

    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = [aws_sns_topic.dmarc.arn]
    }
  }
}

resource "aws_sqs_queue_policy" "dmarc" {
  count     = 1
  region    = var.region
  queue_url = var.queue_url
  policy    = data.aws_iam_policy_document.dmarc_queue[0].json
}

resource "aws_sns_topic_subscription" "dmarc" {
  count                = 1
  region               = var.region
  topic_arn            = aws_sns_topic.dmarc.arn
  protocol             = "sqs"
  endpoint             = var.queue_arn
  raw_message_delivery = false

  depends_on = [aws_sqs_queue_policy.dmarc]
}

resource "aws_ses_receipt_rule" "dmarc" {
  count         = 1
  region        = var.region
  name          = "store-dmarc-reports"
  rule_set_name = var.receipt_rule_set_name
  recipients    = [var.reports_domain]
  enabled       = true
  scan_enabled  = true
  tls_policy    = "Require"

  s3_action {
    position          = 1
    bucket_name       = var.bucket_id
    object_key_prefix = "raw/v1/"
    topic_arn         = aws_sns_topic.dmarc.arn
  }

  depends_on = [
    data.aws_sesv2_email_identity.dmarc_receiving,
    aws_s3_bucket_policy.dmarc,
    aws_sns_topic_policy.dmarc,
  ]
}
