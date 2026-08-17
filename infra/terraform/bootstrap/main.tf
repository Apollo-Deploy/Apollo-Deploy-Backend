data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  state_bucket_name = coalesce(
    var.state_bucket_name,
    "apollo-deploy-terraform-state",
  )
  tags = {
    environment = "production"
    managed_by  = "terraform"
    project     = "apollo-deploy"
    lifecycle   = "bootstrap"
  }
}

resource "terraform_data" "expected_account" {
  input = {
    expected = var.account_id
    actual   = data.aws_caller_identity.current.account_id
  }

  lifecycle {
    precondition {
      condition     = data.aws_caller_identity.current.account_id == var.account_id
      error_message = "The authenticated AWS account does not match account_id."
    }
  }
}

resource "aws_kms_key" "terraform_state" {
  description             = "Apollo production Terraform state encryption"
  deletion_window_in_days = 30
  enable_key_rotation     = true

  tags = merge(local.tags, {
    Name = "apollo-production-terraform-state"
  })

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_kms_alias" "terraform_state" {
  name          = "alias/apollo-production-terraform-state"
  target_key_id = aws_kms_key.terraform_state.key_id
}

resource "aws_s3_bucket" "terraform_state" {
  bucket        = local.state_bucket_name
  force_destroy = false

  tags = merge(local.tags, {
    Name = local.state_bucket_name
  })

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_ownership_controls" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id

  rule {
    apply_server_side_encryption_by_default {
      kms_master_key_id = aws_kms_key.terraform_state.arn
      sse_algorithm     = "aws:kms"
    }
    bucket_key_enabled = true
  }
}

data "aws_iam_policy_document" "terraform_state" {
  statement {
    sid    = "DenyInsecureTransport"
    effect = "Deny"

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    actions = ["s3:*"]
    resources = [
      aws_s3_bucket.terraform_state.arn,
      "${aws_s3_bucket.terraform_state.arn}/*",
    ]

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id
  policy = data.aws_iam_policy_document.terraform_state.json
}

data "aws_iam_policy_document" "operator_alerts_kms" {
  statement {
    sid    = "EnableAccountAdministration"
    effect = "Allow"

    principals {
      type        = "AWS"
      identifiers = ["arn:${data.aws_partition.current.partition}:iam::${var.account_id}:root"]
    }

    actions   = ["kms:*"]
    resources = ["*"]
  }

  statement {
    sid    = "AllowAccountCloudWatchAlarms"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["cloudwatch.amazonaws.com"]
    }

    actions = [
      "kms:Decrypt",
      "kms:GenerateDataKey*",
    ]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [var.account_id]
    }

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:${data.aws_partition.current.partition}:cloudwatch:${var.region}:${var.account_id}:alarm:*"]
    }
  }
}

resource "aws_kms_key" "operator_alerts" {
  description             = "Apollo production operator-alert SNS encryption"
  deletion_window_in_days = 30
  enable_key_rotation     = true
  policy                  = data.aws_iam_policy_document.operator_alerts_kms.json

  tags = merge(local.tags, {
    Name = "apollo-production-operator-alerts"
  })

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_kms_alias" "operator_alerts" {
  name          = "alias/apollo-production-operator-alerts"
  target_key_id = aws_kms_key.operator_alerts.key_id
}

resource "aws_sns_topic" "operator_alerts" {
  name              = var.operator_topic_name
  kms_master_key_id = aws_kms_key.operator_alerts.arn

  tags = merge(local.tags, {
    Name = var.operator_topic_name
  })

  lifecycle {
    prevent_destroy = true
  }
}
