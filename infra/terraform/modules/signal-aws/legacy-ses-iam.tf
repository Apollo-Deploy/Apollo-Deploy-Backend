# This verified BYODKIM identity predates the runtime ownership-tag policy.
# SES lists operator-added tags on the legacy identity but does not expose them
# to IAM resource-tag conditions. Keep the exception exact and in the primary
# region; identities created by the current SES v2 path remain tag-gated.
locals {
  signal_legacy_identity_arn = "arn:${data.aws_partition.current.partition}:ses:${var.region}:${data.aws_caller_identity.current.account_id}:identity/mail.apollodeploy.com"
  signal_primary_tenant_arn  = "arn:${data.aws_partition.current.partition}:ses:${var.region}:${data.aws_caller_identity.current.account_id}:tenant/*/*"
  signal_primary_config_arn  = "arn:${data.aws_partition.current.partition}:ses:${var.region}:${data.aws_caller_identity.current.account_id}:configuration-set/${var.configuration_set_name}"
}

data "aws_iam_policy_document" "signal_legacy_identity" {
  statement {
    sid = "ManageLegacySignalEmailIdentity"
    actions = [
      "ses:DeleteEmailIdentity",
      "ses:GetEmailIdentity",
      "ses:PutEmailIdentityMailFromAttributes",
    ]
    resources = [local.signal_legacy_identity_arn]
  }

  statement {
    sid       = "TagLegacySignalEmailIdentity"
    actions   = ["ses:TagResource"]
    resources = [local.signal_legacy_identity_arn]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/${local.signal_runtime_ses_tag.key}"
      values   = [local.signal_runtime_ses_tag.value]
    }

    condition {
      test     = "ForAllValues:StringEquals"
      variable = "aws:TagKeys"
      values   = local.signal_runtime_ses_tag_keys
    }
  }

  statement {
    sid = "AssociateLegacySignalTenantIdentity"
    actions = [
      "ses:CreateTenantResourceAssociation",
      "ses:DeleteTenantResourceAssociation",
    ]
    resources = [
      local.signal_legacy_identity_arn,
      local.signal_primary_tenant_arn,
      local.signal_primary_config_arn,
    ]
  }
}

resource "aws_iam_policy" "signal_legacy_identity" {
  name   = "${var.name_prefix}-signal-runtime-ses-legacy"
  policy = data.aws_iam_policy_document.signal_legacy_identity.json
  tags   = var.tags
}

resource "aws_iam_user_policy_attachment" "signal_legacy_identity" {
  user       = aws_iam_user.signal.name
  policy_arn = aws_iam_policy.signal_legacy_identity.arn
}
