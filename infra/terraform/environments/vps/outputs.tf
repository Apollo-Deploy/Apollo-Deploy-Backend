output "network" {
  description = "Shared Docker network name"
  value       = module.network.network_name
}

output "containers" {
  description = "All running container names on the VPS"
  value = {
    postgres  = module.infra.postgres_container_name
    pgbouncer = module.infra.pgbouncer_container_name
    redis     = module.infra.redis_container_name
    platform  = module.platform.platform_container_name
    nginx     = module.platform.nginx_container_name
    signal    = module.signal.signal_container_name
    billing   = module.billing.billing_container_name
  }
}

output "public_urls" {
  description = "Public service URLs"
  value = {
    platform_api = "https://api.platform.${var.base_domain}"
    signal_api   = "https://api.signal.${var.base_domain}"
    billing_api  = "https://api.billing.${var.base_domain}"
  }
}

output "m2m_status" {
  description = "OAuth M2M registration status"
  sensitive   = true
  value = {
    signal_client_id   = module.bootstrap.signal_platform_client_id
    billing_client_id  = module.bootstrap.billing_platform_client_id
    trusted_client_ids = module.bootstrap.oauth_trusted_client_ids
    service_client_ids = module.bootstrap.oauth_service_client_ids
  }
}
