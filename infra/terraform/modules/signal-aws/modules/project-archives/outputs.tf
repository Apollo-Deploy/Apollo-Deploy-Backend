output "bucket_id" {
  description = "Project-archive bucket ID."
  value       = aws_s3_bucket.project_archives.id
}

output "bucket_arn" {
  description = "Project-archive bucket ARN."
  value       = aws_s3_bucket.project_archives.arn
}

output "object_arn" {
  description = "ARN pattern covering project-archive objects."
  value       = local.project_archive_object_arn
}

output "kms_key_arn" {
  description = "KMS key ARN protecting project archives."
  value       = aws_kms_key.project_archives.arn
}

output "support_restore_role_arn" {
  description = "Optional project-archive restore role ARN."
  value       = try(aws_iam_role.support_restore[0].arn, null)
}
