output "network" {
  description = "Shared Docker network name."
  value       = module.data_plane.network_name
}

output "containers" {
  description = "Apollo container names grouped across lifecycle planes."
  value       = merge(module.data_plane.containers, module.application_plane.containers)
}

output "durable_volumes" {
  description = "Durable data and TLS volume names; absent capabilities return empty strings."
  value = merge(module.data_plane.volumes, {
    certificates    = module.application_plane.certificate_volumes.certificates
    certbot_webroot = module.application_plane.certificate_volumes.certbot_webroot
  })
}

output "public_urls" {
  description = "Exact public service URLs selected by the deployment interface."
  value = {
    platform_api = local.public_urls.platform
    signal_api   = local.public_urls.signal
    billing_api  = local.public_urls.billing
  }
}

output "release_manifest" {
  description = "Digest-pinned service images and source commits selected by the application plane."
  value       = module.application_plane.releases
}

output "signal_project_archive_encryption" {
  description = "Non-secret Signal project archive bucket and exact runtime KMS key contract."
  value = {
    bucket      = nonsensitive(var.signal.aws.s3_project_archives_bucket)
    kms_key_arn = nonsensitive(var.signal.aws.s3_project_archives_kms_key_arn)
  }
}

output "m2m_status" {
  description = "Terraform-managed OAuth M2M client IDs and allowlists."
  value       = module.identity_plane.status
  sensitive   = true
}

output "reconcile" {
  description = "Sensitive input consumed by infra/scripts/reconcile-services.sh after apply."
  sensitive   = true
  value = {
    transport          = var.deployment.transport.kind
    postgres_container = module.data_plane.containers.postgres
    platform_container = module.application_plane.containers.platform
    billing_container  = module.application_plane.containers.billing
    signal_container   = module.application_plane.containers.signal
    enable_signal      = nonsensitive(var.signal.enabled)
    vps                = var.deployment.transport.ssh
    release = {
      platform = { source_commit = var.deployment.releases.platform.source_commit }
      signal   = { source_commit = var.deployment.releases.signal.source_commit }
      billing  = { source_commit = var.deployment.releases.billing.source_commit }
    }
    database = {
      user        = var.data.database.user
      password    = var.data.database.password
      name        = var.data.database.name
      signal_name = "apollo_deploy_signal"
      roles = {
        platform_app      = var.data.roles.platform_app
        billing_app       = var.data.roles.billing_app
        billing_superuser = var.data.roles.billing_superuser
        signal_app        = var.data.roles.signal_app
        signal_superuser  = var.data.roles.signal_superuser
        platform_verifier = var.data.roles.platform_verifier
      }
    }
    oauth_clients = module.identity_plane.clients
  }
}
