output "signal_platform_client_id" {
  value     = data.external.signal_oauth.result["PLATFORM_CLIENT_ID"]
  sensitive = true
}

output "signal_platform_client_secret" {
  value     = data.external.signal_oauth.result["PLATFORM_CLIENT_SECRET"]
  sensitive = true
}

output "billing_platform_client_id" {
  value     = data.external.billing_oauth.result["PLATFORM_CLIENT_ID"]
  sensitive = true
}

output "billing_platform_client_secret" {
  value     = data.external.billing_oauth.result["PLATFORM_CLIENT_SECRET"]
  sensitive = true
}

output "oauth_trusted_client_ids" {
  value = data.external.platform_oauth_ids.result["OAUTH_TRUSTED_CLIENT_IDS"]
}

output "oauth_service_client_ids" {
  value = data.external.platform_oauth_ids.result["OAUTH_SERVICE_CLIENT_IDS"]
}

output "done" {
  value = terraform_data.register_oauth_clients.id
}
