# =============================================================================
# Outputs — shown after `terraform apply`
# =============================================================================

output "services" {
  description = "Running services and their local URLs"
  value = {
    platform = "https://api.platform.apollodeploy.local  (container: apollo-platform)"
    billing  = "https://api.billing.apollodeploy.local   (container: apollo-billing)"
    signal   = var.enable_signal ? "https://api.signal.apollodeploy.local  (container: apollo-signal)" : "disabled"
  }
}

output "database" {
  description = "Database connection strings for local tooling (TablePlus, psql, etc.)"
  value = {
    direct    = "postgresql://postgres@localhost:5432/apollo_deploy_platform"
    pooled    = "postgresql://postgres@localhost:5433/apollo_deploy_platform"
    signal_db = "postgresql://postgres@localhost:5432/apollo_deploy_signal"
    redis     = "redis://localhost:6379"
  }
}

output "db_password" {
  description = "Auto-generated Postgres superuser password"
  value       = module.secrets.db_password
  sensitive   = true
}

output "redis_password" {
  description = "Auto-generated Redis password"
  value       = module.secrets.redis_password
  sensitive   = true
}

output "m2m_credentials" {
  description = "OAuth M2M client credentials"
  sensitive   = true
  value = {
    platform_client_id     = module.deployment.reconcile.oauth_clients["platform"].client_id
    platform_client_secret = module.deployment.reconcile.oauth_clients["platform"].client_secret
    billing_client_id      = module.deployment.reconcile.oauth_clients["billing"].client_id
    billing_client_secret  = module.deployment.reconcile.oauth_clients["billing"].client_secret
    signal_client_id       = var.enable_signal ? module.deployment.reconcile.oauth_clients["signal"].client_id : "disabled"
    signal_client_secret   = var.enable_signal ? module.deployment.reconcile.oauth_clients["signal"].client_secret : "disabled"
    platform_trusted_ids   = module.deployment.m2m_status.trusted_client_ids
    platform_service_ids   = module.deployment.m2m_status.service_client_ids
  }
}

output "reconcile" {
  description = "Sensitive input consumed by infra/scripts/reconcile-services.sh for manual local reconciliation."
  sensitive   = true
  value       = local.reconcile_payload
}

output "next_steps" {
  description = "What to do after apply"
  value       = <<-MSG

  ✅ Apollo Deploy is running locally!

  Services:
    Platform API → https://api.platform.apollodeploy.local
    Billing API  → https://api.billing.apollodeploy.local
    ${var.enable_signal ? "Signal API   → https://api.signal.apollodeploy.local" : "Signal       → disabled (set enable_signal=true to enable)"}

  Connect to Postgres:
    psql postgresql://postgres@localhost:5432/apollo_deploy_platform

  View credentials:
    terraform output -json db_password
    terraform output -json m2m_credentials

  Logs:
    docker logs -f apollo-platform
    docker logs -f apollo-billing
    ${var.enable_signal ? "docker logs -f apollo-signal" : ""}

  Reconciliation runs automatically after a successful local apply.
  To force a manual rerun:
    bash ../../scripts/reconcile-services.sh local

  Dev mode:
    terraform apply -var='dev_mode=true'
  MSG
}
