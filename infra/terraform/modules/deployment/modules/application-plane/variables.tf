variable "network_name" {
  description = "Docker network shared with the data plane."
  type        = string
}

variable "deployment" {
  description = "Release topology and source paths for the application plane."
  type = object({
    dev_mode         = bool
    signal_enabled   = bool
    metrics_enabled  = bool
    source_root      = string
    nginx_conf_dir   = string
    signal_geoip_dir = string
    releases = object({
      platform = object({ image = string, source_commit = string })
      signal   = object({ image = string, source_commit = string })
      billing  = object({ image = string, source_commit = string })
    })
  })
}

variable "endpoints" {
  description = "Stable service endpoints exposed to application containers."
  type = object({
    base_domain    = string
    platform_url   = string
    postgres_host  = string
    pgbouncer_host = string
    redis_host     = string
  })
}

variable "oauth" {
  description = "Resolved OAuth identities supplied by the identity plane."
  type = object({
    clients            = map(any)
    trusted_client_ids = string
    service_client_ids = string
  })
  sensitive = true
}

variable "credentials" {
  description = "Application database, cache, session, and service credentials."
  type = object({
    database_name              = string
    redis_password             = string
    platform_app_password      = string
    platform_verifier_password = string
    billing_app_password       = string
    billing_superuser_password = string
    signal_app_password        = string
    session_secret             = string
    auth_cookie_secret         = string
    internal_service_secret    = string
  })
  sensitive = true
}

variable "platform" {
  description = "Platform API and edge configuration."
  type = object({
    cors_origins         = string
    login_url            = string
    consent_url          = string
    node_env             = string
    nginx_bind_ip        = string
    disable_origin_check = bool
    disable_csrf_check   = bool
  })
}

variable "certificate_storage" {
  description = "Durable TLS volume capability. Null omits Certbot persistence for local development."
  type = object({
    certificates_volume_name = string
    webroot_volume_name      = string
  })
  default  = null
  nullable = true
}

variable "signal" {
  description = "Signal runtime integrations and credentials. Values are ignored when signal_enabled is false."
  type = object({
    cors_origins                   = string
    aws_extra_regions              = set(string)
    template_media_public_base_url = string
    tracking_base_url              = string
    aws = object({
      region                          = string
      account_id                      = string
      access_key_id                   = string
      secret_access_key               = string
      s3_contact_images_bucket        = string
      s3_template_media_bucket        = string
      s3_dmarc_inbound_bucket         = string
      s3_project_archives_bucket      = string
      s3_project_archives_kms_key_arn = string
      sqs_scheduled_email_queue_url   = string
      sqs_dmarc_inbound_queue_url     = string
      sns_event_topic_arn             = string
      sns_event_topic_arns            = optional(set(string), [])
      sns_dmarc_inbound_topic_arn     = string
      dmarc_ingestion_enabled         = bool
    })
    events_signing_secret  = string
    webhook_secret_key     = string
    import_credentials_key = string
    koog_api_key           = string
  })
  sensitive = true
}

variable "billing" {
  description = "Billing provider configuration and credentials."
  type = object({
    polar_base_url       = string
    polar_api_key        = string
    polar_webhook_secret = string
  })
  sensitive = true
}
