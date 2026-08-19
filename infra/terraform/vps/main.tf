locals {
  name_prefix = "apollo-${var.environment}"
  public_urls = {
    for service, hostname in var.api_hosts : service => "https://${hostname}"
  }
  signal_additional_regions = setsubtract(var.signal.supported_regions, toset([var.aws.region]))
  dmarc_reports_domain      = "reports.${var.base_domain}"
  dmarc_receipt_rule_set    = "${local.name_prefix}-signal-dmarc-inbound"
  tags = {
    environment = var.environment
    managed_by  = "terraform"
    project     = "apollo-deploy"
  }
}

resource "aws_ses_domain_identity" "dmarc_reports" {
  region = var.aws.region
  domain = local.dmarc_reports_domain
}

resource "aws_ses_receipt_rule_set" "dmarc" {
  region        = var.aws.region
  rule_set_name = local.dmarc_receipt_rule_set
}

module "cloudflare_dns" {
  source = "../modules/vps/cloudflare-dns"

  zone_id                      = var.cloudflare.zone_id
  base_domain                  = var.base_domain
  origin_ipv4                  = var.cloudflare.origin_ipv4
  proxied                      = var.cloudflare.proxied
  api_hosts                    = var.api_hosts
  dmarc_ses_verification_token = aws_ses_domain_identity.dmarc_reports.verification_token
  ses_receiving_region         = var.aws.region
}

resource "aws_ses_domain_identity_verification" "dmarc_reports" {
  region = var.aws.region
  domain = aws_ses_domain_identity.dmarc_reports.domain

  depends_on = [module.cloudflare_dns]
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
  dmarc_receipt_rule_set_name            = local.dmarc_receipt_rule_set
  dmarc_reports_domain                   = local.dmarc_reports_domain
  tags                                   = local.tags

  depends_on = [
    aws_ses_domain_identity_verification.dmarc_reports,
    aws_ses_receipt_rule_set.dmarc,
  ]
}

resource "aws_ses_active_receipt_rule_set" "dmarc" {
  region        = var.aws.region
  rule_set_name = aws_ses_receipt_rule_set.dmarc.rule_set_name

  depends_on = [module.signal_aws]
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
