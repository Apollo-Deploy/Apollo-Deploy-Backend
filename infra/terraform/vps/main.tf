locals {
  name_prefix = "apollo-${var.environment}"
  api_hosts = {
    platform = var.server.api_hosts.platform != "" ? var.server.api_hosts.platform : "api.${var.server.base_domain}"
    signal   = var.server.api_hosts.signal != "" ? var.server.api_hosts.signal : "api.signal.${var.server.base_domain}"
    billing  = var.server.api_hosts.billing != "" ? var.server.api_hosts.billing : "api.billing.${var.server.base_domain}"
  }
  public_urls = {
    for service, hostname in local.api_hosts : service => "https://${hostname}"
  }
  configured_signal_regions = nonsensitive(var.signal.supported_regions)
  signal_supported_regions = (
    length(local.configured_signal_regions) > 0
    ? local.configured_signal_regions
    : toset([var.aws.region])
  )
  signal_additional_regions = setsubtract(local.signal_supported_regions, toset([var.aws.region]))
  tags = {
    environment = var.environment
    managed_by  = "terraform"
    project     = "apollo-deploy"
  }

  oauth_client_definitions = [
    for client in jsondecode(file("${path.root}/../../oauth-clients.json")) : {
      key                       = client.key
      name                      = client.name
      is_public                 = try(client.isPublic, false)
      grant_types               = client.grantTypes
      redirect_uris             = ["https://app.${var.server.base_domain}"]
      post_logout_redirect_uris = ["https://app.${var.server.base_domain}"]
      scope                     = client.scope
      skip_consent              = try(client.skipConsent, false)
    }
  ]

  # Non-secret operational values consumed by infra/setup.sh through
  # `terraform console`. Keep secret objects out of this deliberately
  # declassified boundary; only their boolean feature state is exposed.
  # TFLint cannot observe the external console expression in setup.sh.
  # tflint-ignore: terraform_unused_declarations
  wizard_server_config = {
    host           = var.server.host
    user           = var.server.user
    port           = var.server.ssh_port
    key            = var.server.ssh_key_path
    domain         = var.server.base_domain
    email          = var.server.letsencrypt_email
    zone           = var.cloudflare.zone_id
    proxied        = var.cloudflare.proxied
    offsite        = nonsensitive(trimspace(var.backup.r2_bucket) != "")
    dmarc          = nonsensitive(var.signal.enable_dmarc_ingestion)
    aws_region     = var.aws.region
    aws_regions    = sort(tolist(local.signal_supported_regions))
    aws_account_id = var.aws.account_id
    dmarc_identity = "reports.${var.server.base_domain}"
    dmarc_receipt_rule_set = nonsensitive(
      trimspace(var.signal.dmarc_receipt_rule_set_name)
    )
    api_hosts = local.api_hosts
  }
}

module "cloudflare_dns" {
  source = "../modules/vps/cloudflare-dns"

  zone_id                = var.cloudflare.zone_id
  base_domain            = var.server.base_domain
  origin_ipv4            = var.cloudflare.origin_ipv4
  proxied                = var.cloudflare.proxied
  api_hosts              = local.api_hosts
  enable_dmarc_ingestion = nonsensitive(var.signal.enable_dmarc_ingestion)
  ses_receiving_region   = var.aws.region
}

module "signal_aws" {
  source = "../modules/signal-aws"

  name_prefix                = local.name_prefix
  bucket_name_prefix         = "apollo-deploy-${var.environment}"
  region                     = var.aws.region
  additional_service_regions = local.signal_additional_regions
  template_media_allowed_origins = [
    "https://app.${var.server.base_domain}",
  ]
  bucket_name_overrides                  = var.aws.bucket_name_overrides
  archive_retention_days                 = var.aws.archive_retention_days
  operator_alert_topic_arn               = var.aws.operator_alert_topic_arn
  support_restore_trusted_principal_arns = var.aws.support_restore_trusted_principal_arns
  enable_dmarc_ingestion                 = nonsensitive(var.signal.enable_dmarc_ingestion)
  dmarc_receipt_rule_set_name            = nonsensitive(var.signal.dmarc_receipt_rule_set_name)
  dmarc_reports_domain                   = "reports.${var.server.base_domain}"
  tags                                   = local.tags
}

resource "terraform_data" "expected_aws_account" {
  input = {
    expected = var.aws.account_id
    actual   = module.signal_aws.account_id
  }

  lifecycle {
    precondition {
      condition     = module.signal_aws.account_id == var.aws.account_id
      error_message = "The authenticated AWS account does not match aws.account_id; refusing to manage Signal resources in an unexpected account."
    }
  }
}

module "deployment" {
  source = "../modules/deployment"

  deployment = {
    base_domain     = var.server.base_domain
    metrics_enabled = var.metrics_enabled
    public_urls     = local.public_urls
    transport = {
      kind = "ssh"
      ssh = {
        host         = var.server.host
        user         = var.server.user
        ssh_port     = var.server.ssh_port
        ssh_key_path = var.server.ssh_key_path
      }
    }
    releases = var.release_manifest
  }

  durability = {
    persistence  = {}
    certificates = {}
    backup = {
      r2_account_id        = var.backup.r2_account_id
      r2_access_key_id     = var.backup.r2_access_key_id
      r2_secret_access_key = var.backup.r2_secret_access_key
      r2_bucket            = var.backup.r2_bucket
      restic_password      = var.backup.restic_password
    }
  }

  data = {
    database = {
      user     = nonsensitive(var.database.user)
      name     = nonsensitive(var.database.name)
      password = var.database.password
    }
    redis = {
      password = var.database.redis_password
    }
    roles = {
      platform_app      = var.database.platform_app_password
      platform_verifier = var.database.platform_verifier_password
      billing_app       = var.database.billing_app_password
      billing_superuser = var.database.billing_superuser_password
      signal_app        = var.database.signal_app_password
      signal_superuser  = var.database.signal_superuser_password
    }
  }

  identity = {
    oauth_clients           = local.oauth_client_definitions
    session_secret          = var.secrets.session_secret
    auth_cookie_secret      = var.secrets.auth_cookie_secret
    internal_service_secret = var.secrets.internal_service_secret
  }

  platform = {
    public_url = local.public_urls.platform
  }

  billing = {
    polar_api_key        = var.billing.polar_api_key
    polar_webhook_secret = var.billing.polar_webhook_secret
  }

  signal = {
    enabled               = true
    aws_extra_regions     = local.signal_additional_regions
    tracking_base_url     = local.public_urls.signal
    events_signing_secret = var.signal.events_signing_secret
    webhook_secret_key = trimspace(var.signal.webhook_secret_key) != "" ? var.signal.webhook_secret_key : base64sha256(
      "${var.signal.events_signing_secret}:webhook-secrets:v1"
    )
    import_credentials_key = trimspace(var.signal.import_credentials_key) != "" ? var.signal.import_credentials_key : base64sha256(
      "${var.signal.events_signing_secret}:import-credentials:v1"
    )
    koog_api_key = var.signal.koog_api_key
    aws = {
      region                          = var.aws.region
      account_id                      = module.signal_aws.account_id
      access_key_id                   = module.signal_aws.access_key_id
      secret_access_key               = module.signal_aws.secret_access_key
      s3_contact_images_bucket        = module.signal_aws.bucket_names.contact_images
      s3_template_media_bucket        = module.signal_aws.bucket_names.template_media
      s3_dmarc_inbound_bucket         = module.signal_aws.bucket_names.dmarc_inbound
      s3_project_archives_bucket      = module.signal_aws.bucket_names.project_archives
      s3_project_archives_kms_key_arn = module.signal_aws.project_archive_kms_key_arn
      sqs_scheduled_email_queue_url   = module.signal_aws.queue_urls.scheduled_email
      sqs_dmarc_inbound_queue_url     = module.signal_aws.queue_urls.dmarc_inbound
      sns_event_topic_arn             = module.signal_aws.managed_event_topic_arn
      sns_event_topic_arns            = toset(values(module.signal_aws.event_topic_arns))
      sns_dmarc_inbound_topic_arn     = module.signal_aws.dmarc_inbound_topic_arn
      dmarc_ingestion_enabled         = nonsensitive(var.signal.enable_dmarc_ingestion)
    }
  }
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

  # The endpoint verifies the signed SubscriptionConfirmation before visiting
  # its AWS SubscribeURL. On first setup, infra/setup.sh defers this resource
  # until the API has valid TLS and passes its public health check.
  depends_on = [module.deployment]
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

  depends_on = [module.deployment]
}
