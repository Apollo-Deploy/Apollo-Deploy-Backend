data "aws_iam_policy_document" "runtime_storage" {
  statement {
    sid = "UseSignalStorage"
    actions = [
      "s3:GetObject",
      "s3:GetObjectVersion",
      "s3:PutObject",
      "s3:DeleteObject",
      "s3:DeleteObjectVersion",
    ]
    resources = [for arn in values(module.media_storage.bucket_arns) : "${arn}/*"]
  }

  statement {
    sid       = "ListSignalStorage"
    actions   = ["s3:ListBucket", "s3:ListBucketVersions", "s3:GetBucketLocation"]
    resources = values(module.media_storage.bucket_arns)
  }

  statement {
    sid = "ReadProjectArchiveStorage"
    actions = [
      "s3:GetObject",
      "s3:GetObjectVersion",
    ]
    resources = [module.project_archives.object_arn]
  }

  statement {
    sid       = "WriteProjectArchiveStorage"
    actions   = ["s3:PutObject", "s3:AbortMultipartUpload"]
    resources = [module.project_archives.object_arn]
  }

  # Multipart initiation and abort requests do not consistently carry object
  # tag condition keys. Apply tag requirements only to the tagging API itself.
  statement {
    sid       = "TagProjectArchiveStorage"
    actions   = ["s3:PutObjectTagging"]
    resources = [module.project_archives.object_arn]

    condition {
      test     = "StringEquals"
      variable = "s3:RequestObjectTag/data-class"
      values   = ["signal-project-export"]
    }

    condition {
      test     = "Null"
      variable = "s3:RequestObjectTag/archive-id"
      values   = ["false"]
    }

    condition {
      test     = "Null"
      variable = "s3:RequestObjectTag/expires-at"
      values   = ["false"]
    }
  }

  statement {
    sid       = "ListProjectArchiveStorage"
    actions   = ["s3:ListBucket", "s3:GetBucketLocation"]
    resources = [module.project_archives.bucket_arn]
  }

  statement {
    sid = "UseProjectArchiveKey"
    actions = [
      "kms:Decrypt",
      "kms:GenerateDataKey",
    ]
    resources = [module.project_archives.kms_key_arn]

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["s3.${var.region}.amazonaws.com"]
    }

    condition {
      test     = "StringLike"
      variable = "kms:EncryptionContext:aws:s3:arn"
      values   = [module.project_archives.object_arn]
    }
  }
}
