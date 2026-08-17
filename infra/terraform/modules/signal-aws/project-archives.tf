module "project_archives" {
  source = "./modules/project-archives"

  name_prefix                            = var.name_prefix
  bucket_name_prefix                     = var.bucket_name_prefix
  region                                 = var.region
  bucket_name_overrides                  = var.bucket_name_overrides
  archive_retention_days                 = var.archive_retention_days
  runtime_user_arn                       = aws_iam_user.signal.arn
  support_restore_trusted_principal_arns = var.support_restore_trusted_principal_arns
  tags                                   = var.tags
}
