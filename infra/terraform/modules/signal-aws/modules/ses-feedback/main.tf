resource "aws_sns_topic" "event" {
  region            = var.region
  name              = var.event_topic_name
  display_name      = "Apollo Signal SES Events"
  kms_master_key_id = var.messaging_kms_key_arn

  tags = merge(var.tags, {
    service = "signal"
    purpose = "ses-events-managed"
  })

  lifecycle {
    prevent_destroy = true
  }
}

data "aws_iam_policy_document" "event_topic" {
  statement {
    sid    = "OwnerAdministration"
    effect = "Allow"
    actions = [
      "SNS:AddPermission",
      "SNS:DeleteTopic",
      "SNS:GetTopicAttributes",
      "SNS:ListSubscriptionsByTopic",
      "SNS:Publish",
      "SNS:RemovePermission",
      "SNS:SetTopicAttributes",
      "SNS:Subscribe",
    ]
    resources = [aws_sns_topic.event.arn]

    principals {
      type        = "AWS"
      identifiers = ["arn:${var.partition}:iam::${var.account_id}:root"]
    }
  }

  statement {
    sid       = "AllowSESEvents"
    effect    = "Allow"
    actions   = ["SNS:Publish"]
    resources = [aws_sns_topic.event.arn]

    principals {
      type        = "Service"
      identifiers = ["ses.amazonaws.com"]
    }

    condition {
      test     = "ArnLike"
      variable = "AWS:SourceArn"
      values   = ["arn:${var.partition}:ses:${var.region}:${var.account_id}:configuration-set/${var.configuration_set_name}"]
    }
  }
}

resource "aws_sns_topic_policy" "event" {
  region = var.region
  arn    = aws_sns_topic.event.arn
  policy = data.aws_iam_policy_document.event_topic.json
}

resource "aws_sesv2_configuration_set" "signal" {
  region                 = var.region
  configuration_set_name = var.configuration_set_name
  tags = merge(var.tags, {
    apollo_signal_managed = "true"
    apollo_signal_kind    = "shared-configuration-set"
  })

  reputation_options {
    reputation_metrics_enabled = true
  }

  sending_options {
    sending_enabled = true
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_sesv2_configuration_set_event_destination" "managed_event" {
  region                 = var.region
  configuration_set_name = aws_sesv2_configuration_set.signal.configuration_set_name
  event_destination_name = "apollo-signal-sqs"

  event_destination {
    enabled = true
    matching_event_types = [
      "BOUNCE",
      "COMPLAINT",
      "DELIVERY",
      "DELIVERY_DELAY",
      "REJECT",
    ]

    sns_destination {
      topic_arn = aws_sns_topic.event.arn
    }
  }

  depends_on = [aws_sns_topic_policy.event]
}
