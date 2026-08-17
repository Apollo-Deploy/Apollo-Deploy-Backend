# =============================================================================
# Apollo Deploy — Local Developer Environment
#
# `terraform apply` creates the local Docker stack, then automatically
# reconciles migrations, grants, and OAuth records before it completes.
#
# What happens automatically:
#   ✓ Secrets generated (module "secrets")
#   ✓ Docker images built from source
#   ✓ Postgres, PgBouncer, Redis started (module "infra")
#   ✓ Platform API + nginx started (module "platform")
#   ✓ Stable OAuth client credentials generated in state (module "oauth_clients")
#   ✓ Migrations, grants, and OAuth records reconciled
# =============================================================================

terraform {
  required_version = "~> 1.15.0"

  required_providers {
    docker = {
      source  = "kreuzwerker/docker"
      version = "~> 3.9.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.9.0"
    }
  }

  backend "local" {
    path = "terraform.tfstate"
  }
}

provider "docker" {
  host = "unix:///var/run/docker.sock"
}

# ── Absolute paths ────────────────────────────────────────────────────────────
locals {
  repo_root    = abspath("${path.root}/../../../")
  platform_dir = "${local.repo_root}/apollo-platform-api"
  signal_dir   = "${local.repo_root}/apollo-signal-api"
  billing_dir  = "${local.repo_root}/apollo-billing-api"
  infra_dir    = "${local.repo_root}/infra"

  billing_polar_webhook_secret = trimspace(var.polar_webhook_secret) != "" ? var.polar_webhook_secret : try(
    regex(
      "(?m)^POLAR_WEBHOOK_SECRET=([^\\r\\n]*)",
      file("${local.billing_dir}/.env"),
    )[0],
    "",
  )
  signal_tracking_base_url = try(
    regex(
      "(?m)^SIGNAL_TRACKING_BASE_URL=([^\\r\\n]*)",
      file("${local.signal_dir}/.env"),
    )[0],
    "",
  )
  # Match scripts/nginx/conf.d/10-dev.conf (mkcert HTTPS on *.apollodeploy.local).
  # Cookie domain / PLATFORM_URL must use the same registrable domain or browsers
  # reject Set-Cookie (e.g. Domain=.localhost on api.platform.apollodeploy.local).
  base_domain      = "apollodeploy.local"
  runtime_dev_mode = var.dev_mode
  platform_url     = "https://api.platform.${local.base_domain}"
  sns_event_topic_arn = var.aws_account_id == "" ? "" : (
    "arn:aws:sns:${var.aws_region}:${var.aws_account_id}:apollo-signal-ses-events"
  )

  oauth_client_definitions = [
    for client in jsondecode(file("${local.infra_dir}/oauth-clients.json")) : {
      key                       = client.key
      name                      = client.name
      is_public                 = try(client.isPublic, false)
      grant_types               = client.grantTypes
      redirect_uris             = ["https://app.${local.base_domain}"]
      post_logout_redirect_uris = ["https://app.${local.base_domain}"]
      scope                     = client.scope
      skip_consent              = try(client.skipConsent, false)
    } if var.enable_signal || client.key != "signal"
  ]

  # dev_mode: pull base images only — no docker build (seconds, not minutes).
  dev_platform_image = "oven/bun:1.3.11-alpine"
  dev_jvm_image      = "eclipse-temurin:21-jdk-alpine"

  platform_build_files = setunion(
    fileset(local.platform_dir, "src/**"),
    fileset(local.platform_dir, "packages/**"),
    toset(["Dockerfile", ".dockerignore", "package.json", "bun.lock", "build.ts", "tsconfig.json"]),
  )
  billing_build_files = setunion(
    fileset(local.billing_dir, "src/**"),
    fileset(local.billing_dir, "gradle/**"),
    toset(["Dockerfile", ".dockerignore", "gradlew", "settings.gradle.kts", "build.gradle.kts", "gradle.properties"]),
  )
  signal_build_files = setunion(
    fileset(local.signal_dir, "src/**"),
    fileset(local.signal_dir, "gradle/**"),
    fileset(local.signal_dir, "libs/**"),
    toset(["Dockerfile", ".dockerignore", "gradlew", "gradlew.bat", "settings.gradle.kts", "build.gradle.kts", "gradle.properties"]),
  )
}

# =============================================================================
# SECRETS — auto-generated on first apply, stable in state thereafter
# =============================================================================

module "secrets" {
  source = "../modules/local/secrets"
}

# =============================================================================
# DOCKER IMAGES — built from each service's Dockerfile
# =============================================================================

resource "docker_image" "platform" {
  count = local.runtime_dev_mode ? 0 : 1
  name  = "apollo-platform:local"
  build {
    context    = local.platform_dir
    dockerfile = "Dockerfile"
    target     = "production"
    build_args = {
      BUN_INSTALL_DEBUG = var.debug ? "1" : "0"
    }
    build_log_file = var.debug ? "/tmp/apollo-platform-build.log" : null
    secrets {
      id  = "npm_token"
      env = "NPM_TOKEN"
    }
    label = { "managed-by" = "terraform", "env" = "local" }
  }
  triggers = {
    context = sha256(join("", [
      for file in sort(tolist(local.platform_build_files)) :
      "${file}:${filesha256("${local.platform_dir}/${file}")}"
    ]))
  }
}

resource "docker_image" "billing" {
  count = local.runtime_dev_mode ? 0 : 1
  name  = "apollo-billing:local"
  build {
    context    = local.billing_dir
    dockerfile = "Dockerfile"
    label      = { "managed-by" = "terraform", "env" = "local" }
  }
  triggers = {
    context = sha256(join("", [
      for file in sort(tolist(local.billing_build_files)) :
      "${file}:${filesha256("${local.billing_dir}/${file}")}"
    ]))
  }
}

resource "docker_image" "signal" {
  count = var.enable_signal && !local.runtime_dev_mode ? 1 : 0
  name  = "apollo-signal:local"
  build {
    context    = local.signal_dir
    dockerfile = "Dockerfile"
    label      = { "managed-by" = "terraform", "env" = "local" }
  }
  triggers = {
    context = sha256(join("", [
      for file in sort(tolist(local.signal_build_files)) :
      "${file}:${filesha256("${local.signal_dir}/${file}")}"
    ]))
  }
}

module "deployment" {
  source = "../modules/deployment"

  deployment = {
    base_domain = local.base_domain
    transport = {
      kind = "local"
    }
    development = {
      enabled     = local.runtime_dev_mode
      source_root = local.repo_root
    }
    paths = {
      nginx_conf_dir   = "${local.platform_dir}/scripts/nginx"
      signal_geoip_dir = "${local.signal_dir}/geoip"
    }
    releases = {
      platform = {
        image = local.runtime_dev_mode ? local.dev_platform_image : docker_image.platform[0].image_id
      }
      billing = {
        image = local.runtime_dev_mode ? local.dev_jvm_image : docker_image.billing[0].image_id
      }
      signal = {
        image = local.runtime_dev_mode ? local.dev_jvm_image : try(docker_image.signal[0].image_id, local.dev_jvm_image)
      }
    }
  }

  durability = {}

  data = {
    database = {
      password       = module.secrets.db_password
      postgres_port  = 5432
      pgbouncer_port = 5433
    }
    redis = {
      password   = module.secrets.redis_password
      port       = 6379
      max_memory = "256mb"
    }
    roles = {
      platform_app      = module.secrets.platform_app_db_pass
      platform_verifier = module.secrets.platform_verifier_db_pass
      billing_app       = module.secrets.billing_app_db_pass
      billing_superuser = module.secrets.billing_superuser_db_pass
      signal_app        = module.secrets.signal_app_db_pass
      signal_superuser  = module.secrets.signal_superuser_db_pass
    }
  }

  identity = {
    oauth_clients           = local.oauth_client_definitions
    session_secret          = module.secrets.session_secret
    auth_cookie_secret      = module.secrets.auth_cookie_secret
    internal_service_secret = module.secrets.internal_service_secret
  }

  platform = {
    public_url    = local.platform_url
    cors_origins  = "https://app.${local.base_domain},https://auth.${local.base_domain},https://account.${local.base_domain},https://signal.${local.base_domain}"
    login_url     = "https://auth.${local.base_domain}/login"
    consent_url   = "https://auth.${local.base_domain}/oauth/consent"
    node_env      = "development"
    nginx_bind_ip = "127.0.0.1"
  }

  billing = {
    polar_base_url       = "https://sandbox-api.polar.sh"
    polar_api_key        = var.polar_api_key
    polar_webhook_secret = local.billing_polar_webhook_secret
  }

  signal = {
    enabled                        = var.enable_signal
    aws_extra_regions              = setsubtract(var.signal_supported_regions, toset([var.aws_region]))
    template_media_public_base_url = var.template_media_public_base_url
    tracking_base_url              = local.signal_tracking_base_url
    aws = {
      region                          = var.aws_region
      account_id                      = var.aws_account_id
      access_key_id                   = var.aws_access_key_id
      secret_access_key               = var.aws_secret_access_key
      s3_contact_images_bucket        = ""
      s3_template_media_bucket        = var.s3_template_media_bucket
      s3_project_archives_bucket      = var.s3_project_archives_bucket
      s3_project_archives_kms_key_arn = ""
      sqs_scheduled_email_queue_url   = ""
      sns_event_topic_arn             = local.sns_event_topic_arn
      sns_event_topic_arns            = toset(compact([local.sns_event_topic_arn]))
    }
    events_signing_secret = var.signal_events_signing_secret
    webhook_secret_key    = ""
    koog_api_key          = var.koog_api_key
  }
}

locals {
  reconcile_payload = module.deployment.reconcile

  reconciliation_files = merge(
    { for file in fileset("${local.platform_dir}/scripts/migrations", "**") : "platform/${file}" => filesha256("${local.platform_dir}/scripts/migrations/${file}") },
    { for file in fileset("${local.billing_dir}/scripts/migrations", "**") : "billing/${file}" => filesha256("${local.billing_dir}/scripts/migrations/${file}") },
    { for file in fileset("${local.signal_dir}/scripts/migrations", "**") : "signal/${file}" => filesha256("${local.signal_dir}/scripts/migrations/${file}") },
    {
      "infra/scripts/reconcile-services.sh"                                = filesha256("${local.infra_dir}/scripts/reconcile-services.sh")
      "infra/scripts/lib/run-migrations.sh"                                = filesha256("${local.infra_dir}/scripts/lib/run-migrations.sh")
      "infra/scripts/lib/apply-signal-grants.sh"                           = filesha256("${local.infra_dir}/scripts/lib/apply-signal-grants.sh")
      "infra/terraform/modules/docker/oauth-clients/scripts/render-sql.py" = filesha256("${local.infra_dir}/terraform/modules/docker/oauth-clients/scripts/render-sql.py")
    },
  )

  reconciliation_trigger = sha256(jsonencode({
    payload = local.reconcile_payload
    files   = local.reconciliation_files
  }))
}

resource "terraform_data" "local_reconciliation" {
  triggers_replace = [local.reconciliation_trigger]

  depends_on = [
    module.deployment,
  ]

  provisioner "local-exec" {
    command = "bash ${local.infra_dir}/scripts/reconcile-services.sh local"

    environment = {
      APOLLO_RECONCILE_JSON = jsonencode(local.reconcile_payload)
    }
  }
}
