module "ses_feedback" {
  source = "./modules/ses-feedback"

  partition              = data.aws_partition.current.partition
  account_id             = data.aws_caller_identity.current.account_id
  region                 = var.region
  configuration_set_name = var.configuration_set_name
  event_topic_name       = var.managed_event_topic_name
  messaging_kms_key_arn  = module.messaging_encryption.key_arn
  tags                   = var.tags
}

module "additional_messaging_encryption" {
  for_each = var.additional_service_regions
  source   = "./modules/messaging-encryption"

  name_prefix                 = var.name_prefix
  partition                   = data.aws_partition.current.partition
  account_id                  = data.aws_caller_identity.current.account_id
  region                      = each.key
  runtime_user_arn            = aws_iam_user.signal.arn
  managed_event_topic_name    = var.managed_event_topic_name
  configuration_set_name      = var.configuration_set_name
  dmarc_receipt_rule_set_name = null
  tags                        = var.tags
}

module "additional_ses_feedback" {
  for_each = var.additional_service_regions
  source   = "./modules/ses-feedback"

  partition              = data.aws_partition.current.partition
  account_id             = data.aws_caller_identity.current.account_id
  region                 = each.key
  configuration_set_name = var.configuration_set_name
  event_topic_name       = var.managed_event_topic_name
  messaging_kms_key_arn  = module.additional_messaging_encryption[each.key].key_arn
  tags                   = var.tags
}
