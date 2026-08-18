locals {
  name_prefix = "apollo-${var.environment}"
  public_urls = {
    for service, hostname in var.api_hosts : service => "https://${hostname}"
  }
  signal_additional_regions = setsubtract(var.signal.supported_regions, toset([var.aws.region]))
  tags = {
    environment = var.environment
    managed_by  = "terraform"
    project     = "apollo-deploy"
  }
}

module "cloudflare_dns" {
  source = "../modules/vps/cloudflare-dns"

  zone_id                = var.cloudflare.zone_id
  base_domain            = var.base_domain
  origin_ipv4            = var.cloudflare.origin_ipv4
  proxied                = var.cloudflare.proxied
  api_hosts              = var.api_hosts
  enable_dmarc_ingestion = var.signal.enable_dmarc_ingestion
  ses_receiving_region   = var.aws.region
}

module "signal_aws" {
  source = "../modules/signal-aws"

  name_prefix                            = local.name_prefix
  bucket_name_prefix                     = "apollo-deploy-${var.environment}"
  region                                 = var.aws.region
  additional_service_regions             = local.signal_additional_regions
  template_media_allowed_origins         = ["https://app.${var.base_domain}"]
  bucket_name_overrides                  = var.aws.bucket_name_overrides
  archive_retention_days                 = var.aws.archive_retention_days
  operator_alert_topic_arn               = var.aws.operator_alert_topic_arn
  support_restore_trusted_principal_arns = var.aws.support_restore_trusted_principal_arns
  enable_dmarc_ingestion                 = var.signal.enable_dmarc_ingestion
  dmarc_receipt_rule_set_name            = var.signal.dmarc_receipt_rule_set_name
  dmarc_reports_domain                   = "reports.${var.base_domain}"
  tags                                   = local.tags
}

resource "aws_sns_topic_subscription" "signal_ses_events" {
  count = var.enable_ses_feedback_subscription ? 1 : 0

  region    = var.aws.region
  topic_arn = module.signal_aws.managed_event_topic_arn
  protocol  = "https"
  endpoint = coalesce(
    var.ses_feedback_endpoint_override,
    "${local.public_urls.signal}/v1/ses-events/ingest",
  )
  endpoint_auto_confirms          = true
  confirmation_timeout_in_minutes = 5
  raw_message_delivery            = false
}

resource "aws_sns_topic_subscription" "regional_signal_ses_events" {
  for_each = var.enable_ses_feedback_subscription ? module.signal_aws.additional_event_topic_arns : {}

  region    = each.key
  topic_arn = each.value
  protocol  = "https"
  endpoint = coalesce(
    var.ses_feedback_endpoint_override,
    "${local.public_urls.signal}/v1/ses-events/ingest",
  )
  endpoint_auto_confirms          = true
  confirmation_timeout_in_minutes = 5
  raw_message_delivery            = false
}
