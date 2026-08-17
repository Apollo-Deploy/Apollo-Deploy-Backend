# Project-deletion archives are isolated from Signal's public media buckets.
# Versioning and Object Lock preserve every archive for the contractual window
# even if the runtime is compromised or its expiry worker runs prematurely.
locals {
  project_archives_bucket_name = lookup(
    var.bucket_name_overrides,
    "project-archives",
    "${var.bucket_name_prefix}-signal-project-archives",
  )

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

resource "aws_kms_key" "project_archives" {
  description             = "Signal project deletion archives"
  enable_key_rotation     = true
  deletion_window_in_days = 30
  tags = merge(var.tags, {
    service    = "signal"
    data_class = "project-archive-encryption"
  })

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_kms_alias" "project_archives" {
  name          = "alias/${var.name_prefix}-signal-project-archives"
  target_key_id = aws_kms_key.project_archives.key_id
}

resource "aws_s3_bucket" "project_archives" {
  bucket              = local.project_archives_bucket_name
  region              = var.region
  object_lock_enabled = true

  tags = merge(var.tags, {
    Name       = local.project_archives_bucket_name
    service    = "signal"
    data_class = "project-archives"
    purpose    = "signal-project-deletion-archives"
  })

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_versioning" "project_archives" {
  bucket = aws_s3_bucket.project_archives.id
  region = var.region

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_object_lock_configuration" "project_archives" {
  bucket              = aws_s3_bucket.project_archives.id
  region              = var.region
  object_lock_enabled = "Enabled"

  rule {
    default_retention {
      mode = "COMPLIANCE"
      days = var.archive_retention_days
    }
  }

  depends_on = [aws_s3_bucket_versioning.project_archives]
}

locals {
  project_archive_object_arn = "${aws_s3_bucket.project_archives.arn}/archives/*"

  # PutObject is the IAM action evaluated for both a single-request upload and
  # CreateMultipartUpload. Requiring these two headers in the bucket policy
  # prevents a caller from silently falling back to the bucket default or the
  # account's aws/s3 key.
  project_archive_encryption_policy_contract = {
    action                     = "s3:PutObject"
    algorithm_condition_key    = "s3:x-amz-server-side-encryption"
    algorithm                  = "aws:kms"
    kms_key_condition_key      = "s3:x-amz-server-side-encryption-aws-kms-key-id"
    kms_key_arn                = aws_kms_key.project_archives.arn
    deny_missing_algorithm_sid = "DenyProjectArchiveMissingSSEAlgorithm"
    deny_wrong_algorithm_sid   = "DenyProjectArchiveWrongSSEAlgorithm"
    deny_missing_key_sid       = "DenyProjectArchiveMissingKMSKey"
    deny_wrong_key_sid         = "DenyProjectArchiveWrongKMSKey"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "project_archives" {
  bucket = aws_s3_bucket.project_archives.id
  region = var.region

  rule {
    apply_server_side_encryption_by_default {
      kms_master_key_id = aws_kms_key.project_archives.arn
      sse_algorithm     = "aws:kms"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "project_archives" {
  bucket                  = aws_s3_bucket.project_archives.id
  region                  = var.region
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

data "aws_iam_policy_document" "project_archives_bucket" {
  statement {
    sid     = local.s3_tls_only_policy.sid
    effect  = "Deny"
    actions = local.s3_tls_only_policy.actions
    resources = [
      aws_s3_bucket.project_archives.arn,
      "${aws_s3_bucket.project_archives.arn}/*",
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

  statement {
    sid    = "DenyRuntimeArchiveRetentionBypass"
    effect = "Deny"
    actions = [
      "s3:BypassGovernanceRetention",
      "s3:DeleteObject",
      "s3:DeleteObjectVersion",
      "s3:PutObjectLegalHold",
      "s3:PutObjectRetention",
    ]
    resources = [local.project_archive_object_arn]

    principals {
      type        = "AWS"
      identifiers = [var.runtime_user_arn]
    }
  }

  statement {
    sid     = local.project_archive_encryption_policy_contract.deny_missing_algorithm_sid
    effect  = "Deny"
    actions = [local.project_archive_encryption_policy_contract.action]
    resources = [
      local.project_archive_object_arn,
    ]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "Null"
      variable = local.project_archive_encryption_policy_contract.algorithm_condition_key
      values   = ["true"]
    }
  }

  statement {
    sid     = local.project_archive_encryption_policy_contract.deny_wrong_algorithm_sid
    effect  = "Deny"
    actions = [local.project_archive_encryption_policy_contract.action]
    resources = [
      local.project_archive_object_arn,
    ]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "StringNotEquals"
      variable = local.project_archive_encryption_policy_contract.algorithm_condition_key
      values   = [local.project_archive_encryption_policy_contract.algorithm]
    }
  }

  statement {
    sid     = local.project_archive_encryption_policy_contract.deny_missing_key_sid
    effect  = "Deny"
    actions = [local.project_archive_encryption_policy_contract.action]
    resources = [
      local.project_archive_object_arn,
    ]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "Null"
      variable = local.project_archive_encryption_policy_contract.kms_key_condition_key
      values   = ["true"]
    }
  }

  statement {
    sid     = local.project_archive_encryption_policy_contract.deny_wrong_key_sid
    effect  = "Deny"
    actions = [local.project_archive_encryption_policy_contract.action]
    resources = [
      local.project_archive_object_arn,
    ]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "ArnNotEquals"
      variable = local.project_archive_encryption_policy_contract.kms_key_condition_key
      values   = [local.project_archive_encryption_policy_contract.kms_key_arn]
    }
  }
}

resource "aws_s3_bucket_policy" "project_archives" {
  bucket = aws_s3_bucket.project_archives.id
  region = var.region
  policy = data.aws_iam_policy_document.project_archives_bucket.json

  depends_on = [aws_s3_bucket_public_access_block.project_archives]
}

resource "aws_s3_bucket_lifecycle_configuration" "project_archives" {
  bucket = aws_s3_bucket.project_archives.id
  region = var.region

  rule {
    id     = "expire-project-archives-after-90-days"
    status = "Enabled"

    expiration {
      days = var.archive_retention_days
    }

    noncurrent_version_expiration {
      noncurrent_days = 1
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }

  rule {
    id     = "remove-expired-project-archive-delete-markers"
    status = "Enabled"

    expiration {
      expired_object_delete_marker = true
    }
  }

  depends_on = [aws_s3_bucket_object_lock_configuration.project_archives]
}
