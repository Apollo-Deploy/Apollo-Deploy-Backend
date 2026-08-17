locals {
  public_media_bucket_kinds      = toset(["contact-images", "template-media"])
  private_ingestion_bucket_kinds = toset(["dmarc-reports"])

  buckets = {
    for kind in setunion(local.public_media_bucket_kinds, local.private_ingestion_bucket_kinds) : kind => {
      name = lookup(
        var.bucket_name_overrides,
        kind,
        "${var.bucket_name_prefix}-signal-${kind}",
      )
    }
  }

  public_media_buckets = {
    for kind in local.public_media_bucket_kinds : kind => local.buckets[kind]
  }

  private_ingestion_buckets = {
    for kind in local.private_ingestion_bucket_kinds : kind => local.buckets[kind]
  }

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

# Signal uses one primary S3 bucket per data type. The running service receives
# a single bucket name for each type, so creating one set per region only adds
# unused resources and cross-region ownership complexity.
# These two buckets intentionally serve anonymous object reads. Their bucket
# policies still limit public access to GetObject, while ACLs, listing, writes,
# and deletion remain blocked or IAM-only.
resource "aws_s3_bucket" "public_media" {
  for_each = local.public_media_buckets
  bucket   = each.value.name
  region   = var.region

  tags = merge(var.tags, {
    Name       = each.value.name
    service    = "signal"
    data_class = each.key
    purpose    = "signal-${each.key}"
  })

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket" "private_ingestion" {
  for_each = local.private_ingestion_buckets
  bucket   = each.value.name
  region   = var.region

  tags = merge(var.tags, {
    Name       = each.value.name
    service    = "signal"
    data_class = each.key
    purpose    = "signal-${each.key}"
  })

  lifecycle {
    prevent_destroy = true
  }
}

locals {
  signal_buckets = merge(
    aws_s3_bucket.public_media,
    aws_s3_bucket.private_ingestion,
  )
}

resource "aws_s3_bucket_versioning" "this" {
  for_each = local.buckets
  bucket   = local.signal_buckets[each.key].id
  region   = var.region

  versioning_configuration {
    status = "Enabled"
  }
}

# Public media must remain decryptable by anonymous readers. SSE-S3 preserves
# that product contract; customer-managed KMS keys require authenticated KMS
# authorization even when the S3 object policy permits a public GET.
#trivy:ignore:AVD-AWS-0132
resource "aws_s3_bucket_server_side_encryption_configuration" "public_media" {
  for_each = local.public_media_buckets
  bucket   = aws_s3_bucket.public_media[each.key].id
  region   = var.region

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "private_ingestion" {
  for_each = local.private_ingestion_buckets
  bucket   = aws_s3_bucket.private_ingestion[each.key].id
  region   = var.region

  rule {
    bucket_key_enabled = true

    apply_server_side_encryption_by_default {
      kms_master_key_id = var.messaging_kms_key_arn
      sse_algorithm     = "aws:kms"
    }
  }
}

# Public object reads are a fixed product contract, so these two settings
# deliberately permit only the narrowly-scoped bucket policy defined below.
#trivy:ignore:AVD-AWS-0087
#trivy:ignore:AVD-AWS-0093
resource "aws_s3_bucket_public_access_block" "public_media" {
  for_each                = local.public_media_buckets
  bucket                  = aws_s3_bucket.public_media[each.key].id
  region                  = var.region
  block_public_acls       = true
  block_public_policy     = false
  ignore_public_acls      = true
  restrict_public_buckets = false
}

resource "aws_s3_bucket_public_access_block" "private_ingestion" {
  for_each                = local.private_ingestion_buckets
  bucket                  = aws_s3_bucket.private_ingestion[each.key].id
  region                  = var.region
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Signal persists direct S3 URLs for contact images and template media. Only
# object reads are public: listing, uploads, and deletion remain IAM-only.
data "aws_iam_policy_document" "public_media" {
  for_each = toset(["contact-images", "template-media"])

  statement {
    sid       = "AllowPublicObjectRead"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.public_media[each.value].arn}/*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }
  }

  statement {
    sid     = local.s3_tls_only_policy.sid
    effect  = "Deny"
    actions = local.s3_tls_only_policy.actions
    resources = [
      aws_s3_bucket.public_media[each.value].arn,
      "${aws_s3_bucket.public_media[each.value].arn}/*",
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

resource "aws_s3_bucket_policy" "public_media" {
  for_each = data.aws_iam_policy_document.public_media
  bucket   = aws_s3_bucket.public_media[each.key].id
  region   = var.region
  policy   = each.value.json

  depends_on = [aws_s3_bucket_public_access_block.public_media]
}

# Template uploads are direct browser PUTs to a presigned S3 URL. The API's
# CORS origin is passed explicitly so another deployment cannot inherit it.
resource "aws_s3_bucket_cors_configuration" "template_media" {
  bucket = aws_s3_bucket.public_media["template-media"].id
  region = var.region

  cors_rule {
    allowed_headers = ["*"]
    allowed_methods = ["GET", "HEAD", "PUT"]
    allowed_origins = sort(tolist(var.template_media_allowed_origins))
    expose_headers  = ["ETag"]
    max_age_seconds = 3600
  }
}
