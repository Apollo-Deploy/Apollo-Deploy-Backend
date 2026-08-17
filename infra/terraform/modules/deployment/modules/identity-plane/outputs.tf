output "clients" {
  description = "Managed OAuth client records."
  value       = module.oauth_clients.clients
  sensitive   = true
}

output "status" {
  description = "Managed OAuth client IDs and allowlists."
  value = {
    platform_client_id = module.oauth_clients.clients["platform"].client_id
    signal_client_id   = try(module.oauth_clients.clients["signal"].client_id, "")
    billing_client_id  = module.oauth_clients.clients["billing"].client_id
    trusted_client_ids = module.oauth_clients.trusted_client_ids
    service_client_ids = module.oauth_clients.service_client_ids
  }
  sensitive = true
}
