module "dedicated_ip_iam" {
  source = "./modules/dedicated-ip-iam"

  name_prefix                   = var.name_prefix
  partition                     = data.aws_partition.current.partition
  account_id                    = data.aws_caller_identity.current.account_id
  regions                       = local.service_regions
  shared_configuration_set_name = var.configuration_set_name
  runtime_user_name             = aws_iam_user.signal.name
  ownership_tag                 = local.signal_runtime_ses_tag
  tags                          = var.tags
}
