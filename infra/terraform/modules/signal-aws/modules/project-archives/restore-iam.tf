locals {
  support_restore_trusted_principal_arns = var.support_restore_trusted_principal_arns
  support_restore_enabled                = length(var.support_restore_trusted_principal_arns) > 0
}

data "aws_iam_policy_document" "support_restore_assume_role" {
  count = local.support_restore_enabled ? 1 : 0

  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "AWS"
      identifiers = local.support_restore_trusted_principal_arns
    }
  }
}

resource "aws_iam_role" "support_restore" {
  count = local.support_restore_enabled ? 1 : 0

  name               = "${var.name_prefix}-signal-archive-restore"
  assume_role_policy = data.aws_iam_policy_document.support_restore_assume_role[0].json
  tags = merge(var.tags, {
    service = "signal"
    purpose = "project-archive-restore"
  })
}

data "aws_iam_policy_document" "support_restore" {
  count = local.support_restore_enabled ? 1 : 0

  statement {
    sid       = "ListProjectArchives"
    actions   = ["s3:GetBucketLocation", "s3:ListBucket"]
    resources = [aws_s3_bucket.project_archives.arn]
  }

  statement {
    sid = "ReadProjectArchives"
    actions = [
      "s3:GetObject",
      "s3:GetObjectVersion",
    ]
    resources = [local.project_archive_object_arn]
  }

  statement {
    sid       = "DecryptProjectArchives"
    actions   = ["kms:Decrypt"]
    resources = [aws_kms_key.project_archives.arn]

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["s3.${var.region}.amazonaws.com"]
    }

    condition {
      test     = "StringLike"
      variable = "kms:EncryptionContext:aws:s3:arn"
      values   = [local.project_archive_object_arn]
    }
  }
}

resource "aws_iam_role_policy" "support_restore" {
  count = local.support_restore_enabled ? 1 : 0

  name   = "${var.name_prefix}-signal-archive-restore"
  role   = aws_iam_role.support_restore[0].name
  policy = data.aws_iam_policy_document.support_restore[0].json
}
