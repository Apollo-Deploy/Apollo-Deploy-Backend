output "billing_platform_client_id" {
  description = "OAuth client_id registered for the billing service"
  value       = data.external.billing_oauth.result["PLATFORM_CLIENT_ID"]
  sensitive   = true
}

output "billing_platform_client_secret" {
  description = "OAuth client_secret for the billing service"
  value       = data.external.billing_oauth.result["PLATFORM_CLIENT_SECRET"]
  sensitive   = true
}

output "signal_platform_client_id" {
  description = "OAuth client_id for the signal service (empty when enable_signal=false)"
  value       = data.external.signal_oauth.result["PLATFORM_CLIENT_ID"]
  sensitive   = true
}

output "signal_platform_client_secret" {
  description = "OAuth client_secret for the signal service (empty when enable_signal=false)"
  value       = data.external.signal_oauth.result["PLATFORM_CLIENT_SECRET"]
  sensitive   = true
}

output "oauth_trusted_client_ids" {
  description = "Comma-separated trusted client_ids written to platform .env"
  value       = data.external.platform_oauth_ids.result["OAUTH_TRUSTED_CLIENT_IDS"]
}

output "oauth_service_client_ids" {
  description = "Comma-separated service client_ids written to platform .env"
  value       = data.external.platform_oauth_ids.result["OAUTH_SERVICE_CLIENT_IDS"]
}

output "done" {
  description = "Opaque completion token — depend on this to wait for full bootstrap"
  value       = terraform_data.register_oauth_clients.id
}
