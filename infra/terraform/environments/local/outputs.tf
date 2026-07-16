# =============================================================================
# Outputs — shown after `terraform apply`
# =============================================================================

output "services" {
  description = "Running services and their local URLs"
  value = {
    platform = "http://api.platform.localhost  (container: apollo-platform)"
    billing  = "http://localhost:3040           (container: apollo-billing)"
    signal   = var.enable_signal ? "http://api.signal.localhost  (container: apollo-signal)" : "disabled"
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
    billing_client_id     = module.bootstrap.billing_platform_client_id
    billing_client_secret = module.bootstrap.billing_platform_client_secret
    signal_client_id      = var.enable_signal ? module.bootstrap.signal_platform_client_id : "disabled"
    signal_client_secret  = var.enable_signal ? module.bootstrap.signal_platform_client_secret : "disabled"
    platform_trusted_ids  = module.bootstrap.oauth_trusted_client_ids
    platform_service_ids  = module.bootstrap.oauth_service_client_ids
  }
}

output "next_steps" {
  description = "What to do after apply"
  value       = <<-MSG

  ✅ Apollo Deploy is running locally!

  Services:
    Platform API → http://api.platform.localhost
    Billing API  → http://localhost:3040
    ${var.enable_signal ? "Signal API   → http://api.signal.localhost" : "Signal       → disabled (set enable_signal=true to enable)"}

  Connect to Postgres:
    psql postgresql://postgres@localhost:5432/apollo_deploy_platform

  View credentials:
    terraform output -json db_password
    terraform output -json m2m_credentials

  Logs:
    docker logs -f apollo-platform
    docker logs -f apollo-billing
    ${var.enable_signal ? "docker logs -f apollo-signal" : ""}

  Re-run migrations:
    terraform apply -var='migration_trigger=${timestamp()}'
  MSG
}
