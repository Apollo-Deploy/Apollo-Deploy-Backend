terraform {
  required_version = ">= 1.10, < 2.0"

  required_providers {
    docker = {
      source  = "kreuzwerker/docker"
      version = "3.9.0"
    }
  }
}

locals {
  signal_on    = nonsensitive(var.signal.enabled)
  platform_url = var.platform.public_url != "" ? var.platform.public_url : "https://api.platform.${var.deployment.base_domain}"
}

module "data_plane" {
  source = "./modules/data-plane"

  database = {
    user             = var.data.database.user
    name             = var.data.database.name
    password         = var.data.database.password
    redis_password   = var.data.redis.password
    postgres_port    = var.data.database.postgres_port
    pgbouncer_port   = var.data.database.pgbouncer_port
    redis_port       = var.data.redis.port
    redis_max_memory = var.data.redis.max_memory
  }

  persistence    = nonsensitive(var.durability.persistence)
  backup         = var.durability.backup
  backup_enabled = nonsensitive(var.durability.backup != null)
}

module "identity_plane" {
  source = "./modules/identity-plane"

  oauth_clients = nonsensitive(var.identity.oauth_clients)
}

module "application_plane" {
  source = "./modules/application-plane"

  network_name = module.data_plane.network_name

  deployment = {
    dev_mode         = var.deployment.development.enabled
    signal_enabled   = local.signal_on
    metrics_enabled  = var.deployment.metrics_enabled
    source_root      = var.deployment.development.source_root
    nginx_conf_dir   = var.deployment.paths.nginx_conf_dir
    signal_geoip_dir = var.deployment.paths.signal_geoip_dir
    releases         = var.deployment.releases
  }

  endpoints = {
    base_domain    = var.deployment.base_domain
    platform_url   = local.platform_url
    postgres_host  = module.data_plane.containers.postgres
    pgbouncer_host = module.data_plane.containers.pgbouncer
    redis_host     = module.data_plane.containers.redis
  }

  oauth = {
    clients            = module.identity_plane.clients
    trusted_client_ids = module.identity_plane.status.trusted_client_ids
    service_client_ids = module.identity_plane.status.service_client_ids
  }

  credentials = {
    database_name              = var.data.database.name
    redis_password             = var.data.redis.password
    platform_app_password      = var.data.roles.platform_app
    platform_verifier_password = var.data.roles.platform_verifier
    billing_app_password       = var.data.roles.billing_app
    billing_superuser_password = var.data.roles.billing_superuser
    signal_app_password        = var.data.roles.signal_app
    session_secret             = var.identity.session_secret
    auth_cookie_secret         = var.identity.auth_cookie_secret
    internal_service_secret    = var.identity.internal_service_secret
  }

  platform = var.platform

  certificate_storage = nonsensitive(var.durability.certificates)

  signal = {
    cors_origins                   = var.signal.cors_origins
    aws_extra_regions              = var.signal.aws_extra_regions
    template_media_public_base_url = var.signal.template_media_public_base_url
    tracking_base_url              = var.signal.tracking_base_url != "" ? var.signal.tracking_base_url : "https://api.signal.${var.deployment.base_domain}"
    aws                            = var.signal.aws
    events_signing_secret          = var.signal.events_signing_secret
    webhook_secret_key             = var.signal.webhook_secret_key
    koog_api_key                   = var.signal.koog_api_key
  }

  billing = var.billing
}
