variable "environment" {
  description = "Short environment name used in resource names."
  type        = string
  default     = "production"

  validation {
    condition     = can(regex("^[a-z0-9-]+$", var.environment))
    error_message = "environment must contain lowercase letters, numbers, and hyphens only."
  }
}

variable "server" {
  description = "Existing VPS and public-domain configuration."
  type = object({
    host              = string
    user              = optional(string, "root")
    ssh_port          = optional(number, 22)
    ssh_key_path      = optional(string, "~/.ssh/id_ed25519")
    base_domain       = string
    letsencrypt_email = string
  })
}

variable "cloudflare" {
  description = "Cloudflare zone and public VPS origin used by the three API DNS records. Authenticate with CLOUDFLARE_API_TOKEN."
  type = object({
    zone_id     = string
    origin_ipv4 = string
    proxied     = optional(bool, true)
  })

  validation {
    condition     = can(regex("^[0-9a-fA-F]{32}$", var.cloudflare.zone_id))
    error_message = "cloudflare.zone_id must be a 32-character Cloudflare zone ID."
  }

  validation {
    condition = (
      can(cidrhost("${var.cloudflare.origin_ipv4}/32", 0)) &&
      !can(regex("^(?:(?:0|10|127)[.]|100[.](?:6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])[.]|169[.]254[.]|172[.](?:1[6-9]|2[0-9]|3[01])[.]|192[.](?:0[.](?:0|2)[.]|168[.])|198[.](?:1[89][.]|51[.]100[.])|203[.]0[.]113[.]|(?:22[4-9]|23[0-9]|24[0-9]|25[0-5])[.])", var.cloudflare.origin_ipv4))
    )
    error_message = "cloudflare.origin_ipv4 must be a globally routable unicast IPv4 address, not a private, loopback, link-local, documentation, multicast, or reserved address."
  }
}

variable "release_manifest" {
  description = "Immutable per-service GHCR images and their audited source commits."
  type = object({
    platform = object({
      image         = string
      source_commit = string
    })
    signal = object({
      image         = string
      source_commit = string
    })
    billing = object({
      image         = string
      source_commit = string
    })
  })

  validation {
    condition = alltrue([
      for service, release in var.release_manifest : can(regex(
        "^ghcr[.]io/apollo-deploy/apollo-${service}-api@sha256:[0-9a-f]{64}$",
        release.image,
      ))
    ])
    error_message = "Every release_manifest image must use its exact ghcr.io/apollo-deploy Apollo service repository pinned by a lowercase sha256 digest."
  }

  validation {
    condition = alltrue([
      for release in values(var.release_manifest) : can(regex("^[0-9a-f]{40}$", release.source_commit))
    ])
    error_message = "Every release_manifest source_commit must be a full 40-character lowercase hexadecimal Git commit."
  }
}

variable "registry_credentials" {
  description = "GHCR pull credentials, kept separate from the non-secret immutable release manifest."
  type = object({
    username = string
    token    = string
  })
  sensitive = true

  validation {
    condition = (
      trimspace(var.registry_credentials.username) != "" &&
      trimspace(var.registry_credentials.token) != "" &&
      !startswith(lower(trimspace(var.registry_credentials.token)), "changeme") &&
      !startswith(lower(trimspace(var.registry_credentials.token)), "replace-") &&
      !contains([
        "change-me",
        "changeme",
        "example",
        "placeholder",
        "replace-me",
        "replace-with-ghcr-read-token",
      ], lower(trimspace(var.registry_credentials.token)))
    )
    error_message = "registry_credentials must provide a non-empty GHCR username and a real read token, not a documented placeholder."
  }
}

variable "database" {
  description = "PostgreSQL, Redis, and scoped application-role credentials."
  type = object({
    user                       = optional(string, "postgres")
    name                       = optional(string, "apollo_deploy_platform")
    password                   = string
    redis_password             = string
    platform_app_password      = string
    billing_app_password       = string
    billing_superuser_password = string
    signal_app_password        = string
    signal_superuser_password  = string
    platform_verifier_password = string
  })
  sensitive = true

  validation {
    condition = alltrue([
      for value in [
        var.database.password,
        var.database.redis_password,
        var.database.platform_app_password,
        var.database.billing_app_password,
        var.database.billing_superuser_password,
        var.database.signal_app_password,
        var.database.signal_superuser_password,
        var.database.platform_verifier_password,
      ] : length(value) >= 16
    ])
    error_message = "All database and Redis passwords must contain at least 16 characters."
  }

  validation {
    condition = alltrue([
      for value in [
        var.database.password,
        var.database.redis_password,
        var.database.platform_app_password,
        var.database.billing_app_password,
        var.database.billing_superuser_password,
        var.database.signal_app_password,
        var.database.signal_superuser_password,
        var.database.platform_verifier_password,
        ] : (
        !startswith(lower(trimspace(value)), "changeme") &&
        !startswith(lower(trimspace(value)), "replace-") &&
        !contains([
          "change-me",
          "example-password",
          "placeholder",
        ], lower(trimspace(value)))
      )
    ])
    error_message = "Database and Redis passwords must not use a documented placeholder value."
  }

  validation {
    condition = length(toset([
      var.database.password,
      var.database.redis_password,
      var.database.platform_app_password,
      var.database.billing_app_password,
      var.database.billing_superuser_password,
      var.database.signal_app_password,
      var.database.signal_superuser_password,
      var.database.platform_verifier_password,
    ])) == 8
    error_message = "PostgreSQL root, Redis, and every scoped database role must use a distinct password."
  }
}

variable "secrets" {
  description = "Platform session and Signal internal-service secrets."
  type = object({
    session_secret          = string
    auth_cookie_secret      = string
    internal_service_secret = string
  })
  sensitive = true

  validation {
    condition = alltrue([
      for value in values(var.secrets) : length(value) >= 32
    ])
    error_message = "Every shared secret must contain at least 32 characters."
  }

  validation {
    condition = alltrue([
      for value in values(var.secrets) : (
        !startswith(lower(trimspace(value)), "changeme") &&
        !startswith(lower(trimspace(value)), "replace-") &&
        !contains([
          "change-me",
          "placeholder",
        ], lower(trimspace(value)))
      )
    ])
    error_message = "Shared secrets must not use a documented placeholder value."
  }

  validation {
    condition     = length(toset(values(var.secrets))) == length(values(var.secrets))
    error_message = "Session, cookie, and internal-service trust boundaries must use distinct secrets."
  }

  validation {
    condition = length(toset(concat(
      values(var.secrets),
      [
        var.database.password,
        var.database.redis_password,
        var.database.platform_app_password,
        var.database.billing_app_password,
        var.database.billing_superuser_password,
        var.database.signal_app_password,
        var.database.signal_superuser_password,
        var.database.platform_verifier_password,
      ],
    ))) == 11
    error_message = "Shared application secrets must not reuse a database or Redis credential."
  }
}

variable "aws" {
  description = "Expected AWS account, Signal region, operator alert topic, optional bucket names, and archive restore-role trust."
  type = object({
    account_id                             = string
    region                                 = optional(string, "af-south-1")
    operator_alert_topic_arn               = string
    bucket_name_overrides                  = optional(map(string), {})
    archive_retention_days                 = optional(number, 90)
    support_restore_trusted_principal_arns = optional(set(string), [])
  })

  validation {
    condition     = can(regex("^[0-9]{12}$", var.aws.account_id))
    error_message = "aws.account_id must be the expected 12-digit AWS account ID."
  }

  validation {
    condition = try(
      can(regex("^arn:[a-z0-9-]+:sns:[a-z0-9-]+:[0-9]{12}:[A-Za-z0-9_-]{1,256}$", var.aws.operator_alert_topic_arn)) &&
      split(":", var.aws.operator_alert_topic_arn)[3] == var.aws.region &&
      split(":", var.aws.operator_alert_topic_arn)[4] == var.aws.account_id,
      false,
    )
    error_message = "aws.operator_alert_topic_arn must be an SNS topic in aws.account_id and aws.region."
  }

  validation {
    condition     = var.aws.archive_retention_days == 90
    error_message = "aws.archive_retention_days must remain 90 days."
  }

  validation {
    condition     = alltrue([for arn in var.aws.support_restore_trusted_principal_arns : can(regex("^arn:[^:]+:iam::[0-9]{12}:.+$", arn))])
    error_message = "aws.support_restore_trusted_principal_arns must contain IAM principal ARNs."
  }
}

variable "signal" {
  description = "Optional Signal integrations and feature secrets."
  type = object({
    supported_regions           = optional(set(string), [])
    events_signing_secret       = optional(string, "")
    webhook_secret_key          = optional(string, "")
    enable_dmarc_ingestion      = optional(bool, false)
    dmarc_receipt_rule_set_name = optional(string, "")
    koog_api_key                = optional(string, "")
  })

  validation {
    condition = alltrue([
      for region in var.signal.supported_regions : contains([
        "af-south-1",
        "ap-southeast-1",
        "eu-west-1",
        "us-east-1",
      ], region)
    ])
    error_message = "signal.supported_regions may contain only af-south-1, ap-southeast-1, eu-west-1, or us-east-1."
  }

  validation {
    condition = (
      length(var.signal.supported_regions) == 0 ||
      contains(var.signal.supported_regions, var.aws.region)
    )
    error_message = "signal.supported_regions must include aws.region when explicitly configured."
  }
  sensitive = true
  default   = {}

  validation {
    condition = (
      !var.signal.enable_dmarc_ingestion ||
      trimspace(var.signal.dmarc_receipt_rule_set_name) != ""
    )
    error_message = "signal.dmarc_receipt_rule_set_name must name an existing, active SES receipt rule set when DMARC ingestion is enabled."
  }

  validation {
    condition = (
      var.environment != "production" ||
      (
        length(var.signal.events_signing_secret) >= 32 &&
        !startswith(lower(trimspace(var.signal.events_signing_secret)), "changeme") &&
        !startswith(lower(trimspace(var.signal.events_signing_secret)), "replace-") &&
        !contains([
          "change-me",
          "changeme",
          "placeholder",
          "replace-me",
          "replace-with-at-least-32-random-characters",
        ], lower(trimspace(var.signal.events_signing_secret)))
      )
    )
    error_message = "signal.events_signing_secret must contain at least 32 non-placeholder characters in production so tracking and unsubscribe links cannot fail open."
  }

  validation {
    condition = (
      var.environment != "production" ||
      length(toset(concat(
        values(var.secrets),
        [
          var.database.password,
          var.database.redis_password,
          var.database.platform_app_password,
          var.database.billing_app_password,
          var.database.billing_superuser_password,
          var.database.signal_app_password,
          var.database.signal_superuser_password,
          var.database.platform_verifier_password,
          var.signal.events_signing_secret,
        ],
        compact([var.signal.webhook_secret_key]),
      ))) == 12 + length(compact([var.signal.webhook_secret_key]))
    )
    error_message = "Signal signing and webhook secrets must be distinct from every database, Redis, session, cookie, and internal-service credential in production."
  }
}

variable "billing" {
  description = "Optional Polar integration."
  type = object({
    polar_api_key        = optional(string, "")
    polar_webhook_secret = optional(string, "")
  })
  sensitive = true
  default   = {}
}

variable "backup" {
  description = "Optional encrypted PostgreSQL backup target in Cloudflare R2."
  type = object({
    r2_account_id        = optional(string, "")
    r2_access_key_id     = optional(string, "")
    r2_secret_access_key = optional(string, "")
    r2_bucket            = optional(string, "")
    restic_password      = optional(string, "")
  })
  sensitive = true
  default   = {}

  validation {
    condition = alltrue([
      for value in [
        var.backup.r2_account_id,
        var.backup.r2_access_key_id,
        var.backup.r2_secret_access_key,
        var.backup.r2_bucket,
        var.backup.restic_password,
      ] : value == ""
      ]) || (
      can(regex("^[0-9a-fA-F]{32}$", var.backup.r2_account_id)) &&
      length(var.backup.r2_access_key_id) >= 8 &&
      length(var.backup.r2_secret_access_key) >= 16 &&
      can(regex("^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$", var.backup.r2_bucket)) &&
      length(var.backup.restic_password) >= 20
    )
    error_message = "Leave every backup field empty to disable offsite upload, or provide a 32-hex-character R2 account ID, valid bucket, complete credentials, and a 20+ character restic password."
  }
}

variable "metrics_enabled" {
  description = "Enable Platform metrics."
  type        = bool
  default     = false
}

variable "enable_ses_feedback_subscription" {
  description = "Subscribe Signal's signed HTTPS ingestion endpoint to the existing managed SES-events SNS topic."
  type        = bool
  default     = true
}
