output "bucket_ids" {
  description = "Signal media and private-ingestion bucket IDs keyed by data class."
  value = merge(
    { for kind, bucket in aws_s3_bucket.public_media : kind => bucket.id },
    { for kind, bucket in aws_s3_bucket.private_ingestion : kind => bucket.id },
  )
}

output "bucket_arns" {
  description = "Signal media and private-ingestion bucket ARNs keyed by data class."
  value = merge(
    { for kind, bucket in aws_s3_bucket.public_media : kind => bucket.arn },
    { for kind, bucket in aws_s3_bucket.private_ingestion : kind => bucket.arn },
  )
}
