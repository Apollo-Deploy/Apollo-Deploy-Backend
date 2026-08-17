module "messaging_encryption" {
  source = "./modules/messaging-encryption"

  name_prefix                 = var.name_prefix
  partition                   = data.aws_partition.current.partition
  account_id                  = data.aws_caller_identity.current.account_id
  region                      = var.region
  runtime_user_arn            = aws_iam_user.signal.arn
  managed_event_topic_name    = var.managed_event_topic_name
  configuration_set_name      = var.configuration_set_name
  enable_dmarc_ingestion      = var.enable_dmarc_ingestion
  dmarc_receipt_rule_set_name = var.dmarc_receipt_rule_set_name
  tags                        = var.tags
}
