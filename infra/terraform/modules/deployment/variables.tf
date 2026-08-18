variable "deployment" {
  description = "Release identity, public domain, source paths, and non-secret runtime behavior."
  type = object({
    base_domain     = string
    metrics_enabled = optional(bool, false)
    transport = object({
      kind = string
      ssh = optional(object({
        host         = optional(string, "")
        user         = optional(string, "root")
        ssh_port     = optional(number, 22)
        ssh_key_path = optional(string, "~/.ssh/id_ed25519")
      }), {})
    })
    development = optional(object({
      enabled     = optional(bool, false)
      source_root = optional(string, "/opt/apollo/src")
    }), {})
    paths = optional(object({
      nginx_conf_dir   = optional(string, "/opt/apollo/platform/nginx")
      signal_geoip_dir = optional(string, "/opt/apollo/signal/geoip")
    }), {})
    releases = object({
      platform = object({ image = string, source_commit = optional(string, "") })
      signal   = object({ image = string, source_commit = optional(string, "") })
      billing  = object({ image = string, source_commit = optional(string, "") })
    })
  })

  validation {
    condition = var.deployment.development.enabled || alltrue([
      for service, release in var.deployment.releases : (
        can(regex("^ghcr[.]io/apollo-deploy/apollo-${service}-api@sha256:[0-9a-f]{64}$", release.image)) &&
        can(regex("^[0-9a-f]{40}$", release.source_commit))
      )
    ])
    error_message = "Non-development releases must use the exact Apollo Deploy GHCR repository, a sha256 digest, and a full 40-hex source commit."
  }

  validation {
    condition     = contains(["local", "ssh"], var.deployment.transport.kind)
    error_message = "deployment.transport.kind must be local or ssh."
  }
}

variable "durability" {
  description = "Explicit durable capabilities. Null values omit that lifecycle without inferring behavior from an environment name."
  type = object({
    persistence = optional(object({
      postgres_volume_name = optional(string, "apollo-postgres-data")
      redis_volume_name    = optional(string, "apollo-redis-data")
    }))
    certificates = optional(object({
      certificates_volume_name = optional(string, "apollo-letsencrypt-certs")
      webroot_volume_name      = optional(string, "apollo-certbot-webroot")
    }))
    backup = optional(object({
      r2_account_id        = string
      r2_access_key_id     = string
      r2_secret_access_key = string
      r2_bucket            = string
      restic_password      = string
    }))
  })
  default = {}

  validation {
    condition     = var.durability.backup == null || var.durability.persistence != null
    error_message = "Backups require durable database persistence."
  }

  sensitive = true
}

variable "data" {
  description = "Data-plane configuration and credentials."
  type = object({
    database = object({
      user           = optional(string, "postgres")
      name           = optional(string, "apollo_deploy_platform")
      password       = string
      postgres_port  = optional(number, 0)
      pgbouncer_port = optional(number, 0)
    })
    redis = object({
      password   = string
      port       = optional(number, 0)
      max_memory = optional(string, "512mb")
    })
    roles = object({
      platform_app      = string
      platform_verifier = string
      billing_app       = string
      billing_superuser = string
      signal_app        = string
      signal_superuser  = string
    })
  })
  sensitive = true
}

variable "identity" {
  description = "OAuth topology and shared authentication credentials."
  type = object({
    oauth_clients = list(object({
      key                       = string
      name                      = string
      is_public                 = bool
      grant_types               = list(string)
      redirect_uris             = list(string)
      post_logout_redirect_uris = list(string)
      scope                     = string
      skip_consent              = bool
    }))
    session_secret          = string
    auth_cookie_secret      = string
    internal_service_secret = string
  })
  sensitive = true
}

variable "platform" {
  description = "Platform API and edge runtime contract."
  type = object({
    public_url           = optional(string, "")
    cors_origins         = optional(string, "")
    login_url            = optional(string, "")
    consent_url          = optional(string, "")
    node_env             = optional(string, "production")
    nginx_bind_ip        = optional(string, "0.0.0.0")
    disable_origin_check = optional(bool, false)
    disable_csrf_check   = optional(bool, false)
  })
  default = {}
}

variable "signal" {
  description = "Signal API runtime and AWS integration contract."
  type = object({
    enabled                        = bool
    aws_extra_regions              = optional(set(string), [])
    cors_origins                   = optional(string, "")
    template_media_public_base_url = optional(string, "")
    tracking_base_url              = optional(string, "")
    aws = object({
      region                          = string
      account_id                      = string
      access_key_id                   = string
      secret_access_key               = string
      s3_contact_images_bucket        = string
      s3_template_media_bucket        = string
      s3_dmarc_inbound_bucket         = optional(string, "")
      s3_project_archives_bucket      = string
      s3_project_archives_kms_key_arn = string
      sqs_scheduled_email_queue_url   = string
      sqs_dmarc_inbound_queue_url     = optional(string, "")
      sns_event_topic_arn             = string
      sns_event_topic_arns            = optional(set(string), [])
      sns_dmarc_inbound_topic_arn     = optional(string, "")
      dmarc_ingestion_enabled         = optional(bool, false)
    })
    events_signing_secret  = string
    webhook_secret_key     = string
    import_credentials_key = optional(string, "")
    koog_api_key           = string
  })
  sensitive = true
}

variable "billing" {
  description = "Billing API and Polar integration contract."
  type = object({
    polar_base_url       = optional(string, "https://api.polar.sh")
    polar_api_key        = string
    polar_webhook_secret = string
  })
  sensitive = true
}

check "oauth_topology" {
  assert {
    condition = (
      toset([for client in nonsensitive(var.identity.oauth_clients) : client.key]) ==
      (nonsensitive(var.signal.enabled) ? toset(["platform", "signal", "billing"]) : toset(["platform", "billing"]))
    )
    error_message = "identity.oauth_clients must contain the enabled canonical services exactly once."
  }
}
