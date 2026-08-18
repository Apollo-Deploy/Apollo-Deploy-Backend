resource "docker_volume" "certificates" {
  count = var.certificate_storage == null ? 0 : 1

  name = var.certificate_storage.certificates_volume_name

  lifecycle {
    prevent_destroy = true
  }
}

resource "docker_volume" "certbot_webroot" {
  count = var.certificate_storage == null ? 0 : 1

  name = var.certificate_storage.webroot_volume_name

  lifecycle {
    prevent_destroy = true
  }
}

module "platform" {
  source = "../../../profiles/platform-api/modules/service"

  network_name  = var.network_name
  image         = var.deployment.releases.platform.image
  source_commit = var.deployment.releases.platform.source_commit
  dev_mode      = var.deployment.dev_mode
  source_dir    = var.deployment.dev_mode ? "${var.deployment.source_root}/apollo-platform-api" : ""
  certificate_volumes = var.certificate_storage == null ? {} : {
    certificates = var.certificate_storage.certificates_volume_name
    webroot      = var.certificate_storage.webroot_volume_name
  }

  depends_on = [
    docker_volume.certificates,
    docker_volume.certbot_webroot,
  ]

  db = {
    host              = var.endpoints.pgbouncer_host
    user              = "platform_app"
    password          = var.credentials.platform_app_password
    name              = var.credentials.database_name
    verifier_host     = var.endpoints.postgres_host
    verifier_user     = "platform_verifier"
    verifier_password = var.credentials.platform_verifier_password
  }

  redis = {
    host     = var.endpoints.redis_host
    password = var.credentials.redis_password
  }

  auth = {
    platform_url         = var.endpoints.platform_url
    platform_public_url  = var.endpoints.platform_url
    cors_origins         = var.platform.cors_origins
    session_secret       = var.credentials.session_secret
    cookie_secret        = var.credentials.auth_cookie_secret
    secure_cookies       = true
    cookie_domain        = ".${var.endpoints.base_domain}"
    login_url            = var.platform.login_url != "" ? var.platform.login_url : "https://app.${var.endpoints.base_domain}/login"
    consent_url          = var.platform.consent_url != "" ? var.platform.consent_url : "https://app.${var.endpoints.base_domain}/oauth/consent"
    disable_origin_check = var.platform.disable_origin_check
    disable_csrf_check   = var.platform.disable_csrf_check
  }

  oauth = {
    client_id          = var.oauth.clients["platform"].client_id
    client_secret      = var.oauth.clients["platform"].client_secret
    trusted_client_ids = var.oauth.trusted_client_ids
    service_client_ids = var.oauth.service_client_ids
  }

  service = {
    node_env         = var.platform.node_env
    billing_base_url = "http://apollo-billing:3040"
    signal_base_url  = var.deployment.signal_enabled ? "http://apollo-signal:3030" : ""
    metrics_enabled  = var.deployment.metrics_enabled
  }

  nginx = {
    conf_dir = var.deployment.nginx_conf_dir
    bind_ip  = var.platform.nginx_bind_ip
  }
}

module "signal" {
  count  = var.deployment.signal_enabled ? 1 : 0
  source = "../../../profiles/signal-api/modules/service"

  network_name  = var.network_name
  image         = var.deployment.releases.signal.image
  source_commit = var.deployment.releases.signal.source_commit
  dev_mode      = var.deployment.dev_mode
  source_dir    = var.deployment.dev_mode ? "${var.deployment.source_root}/apollo-signal-api" : ""

  db = {
    password = var.credentials.signal_app_password
    sslmode  = "disable"
  }

  redis = {
    password = var.credentials.redis_password
  }

  oauth = {
    platform_audience_url   = var.endpoints.platform_url
    client_id               = var.oauth.clients["signal"].client_id
    client_secret           = var.oauth.clients["signal"].client_secret
    issuer_url              = var.endpoints.platform_url
    valid_audiences         = var.endpoints.platform_url
    internal_service_secret = var.credentials.internal_service_secret
    session_secret          = var.credentials.session_secret
    secure_cookies          = true
    cors_origins            = var.signal.cors_origins
    service_client_ids      = var.oauth.clients["platform"].client_id
  }

  aws = {
    region                          = var.signal.aws.region
    extra_regions                   = var.signal.aws_extra_regions
    access_key_id                   = var.signal.aws.access_key_id
    secret_access_key               = var.signal.aws.secret_access_key
    account_id                      = var.signal.aws.account_id
    sqs_scheduled_email_url         = var.signal.aws.sqs_scheduled_email_queue_url
    sqs_dmarc_inbound_url           = var.signal.aws.sqs_dmarc_inbound_queue_url
    sns_event_topic_arn             = var.signal.aws.sns_event_topic_arn
    sns_event_topic_arns            = var.signal.aws.sns_event_topic_arns
    sns_dmarc_inbound_topic_arn     = var.signal.aws.sns_dmarc_inbound_topic_arn
    s3_contact_images_bucket        = var.signal.aws.s3_contact_images_bucket
    s3_dmarc_inbound_bucket         = var.signal.aws.s3_dmarc_inbound_bucket
    s3_project_archives_bucket      = var.signal.aws.s3_project_archives_bucket
    s3_project_archives_kms_key_arn = var.signal.aws.s3_project_archives_kms_key_arn
    dmarc_ingestion_enabled         = var.signal.aws.dmarc_ingestion_enabled
  }

  storage = {
    bucket          = var.signal.aws.s3_template_media_bucket
    public_base_url = var.signal.template_media_public_base_url
  }

  features = {
    events_signing_secret  = var.signal.events_signing_secret
    webhook_secret_key     = var.signal.webhook_secret_key
    import_credentials_key = var.signal.import_credentials_key
    tracking_base_url      = var.signal.tracking_base_url
    koog_api_key           = var.signal.koog_api_key
    billing_base_url       = "http://apollo-billing:3040"
  }

  geoip_host_path = var.deployment.signal_geoip_dir
}

module "billing" {
  source = "../../../profiles/billing-api/modules/service"

  network_name  = var.network_name
  image         = var.deployment.releases.billing.image
  source_commit = var.deployment.releases.billing.source_commit
  dev_mode      = var.deployment.dev_mode
  source_dir    = var.deployment.dev_mode ? "${var.deployment.source_root}/apollo-billing-api" : ""

  db = {
    password           = var.credentials.billing_app_password
    superuser_password = var.credentials.billing_superuser_password
  }

  redis = {
    password = var.credentials.redis_password
  }

  oauth = {
    platform_url          = "http://apollo-platform:3000"
    platform_audience_url = var.endpoints.platform_url
    issuer_url            = var.endpoints.platform_url
    valid_audiences       = var.endpoints.platform_url
    client_id             = var.oauth.clients["billing"].client_id
    client_secret         = var.oauth.clients["billing"].client_secret
    jwks_url              = "http://apollo-platform:3000/auth/jwks"
    service_client_ids = join(",", compact([
      var.oauth.clients["platform"].client_id,
      var.deployment.signal_enabled ? var.oauth.clients["signal"].client_id : "",
    ]))
  }

  polar = {
    api_key        = var.billing.polar_api_key
    webhook_secret = var.billing.polar_webhook_secret
    base_url       = var.billing.polar_base_url
  }
}
