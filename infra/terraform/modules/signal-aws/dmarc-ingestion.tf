module "dmarc_ingestion" {
  source = "./modules/dmarc-ingestion"

  name_prefix               = var.name_prefix
  partition                 = data.aws_partition.current.partition
  account_id                = data.aws_caller_identity.current.account_id
  region                    = var.region
  receipt_rule_set_name     = var.dmarc_receipt_rule_set_name
  reports_domain            = var.dmarc_reports_domain
  current_retention_days    = var.dmarc_current_retention_days
  noncurrent_retention_days = var.dmarc_noncurrent_retention_days
  bucket_id                 = module.media_storage.bucket_ids["dmarc-reports"]
  bucket_arn                = module.media_storage.bucket_arns["dmarc-reports"]
  queue_url                 = module.message_queues.queue_urls["dmarc-reports"]
  queue_arn                 = module.message_queues.queue_arns["dmarc-reports"]
  messaging_kms_key_arn     = module.messaging_encryption.key_arn

  depends_on = [module.media_storage]
}
