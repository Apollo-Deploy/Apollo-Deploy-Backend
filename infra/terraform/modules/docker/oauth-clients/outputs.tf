output "clients" {
  description = "Managed OAuth client definitions and plaintext credentials, keyed by stable client key."
  sensitive   = true
  value = {
    for key in sort(keys(local.clients_by_key)) : key => {
      record_id                 = random_uuid.record_id[key].result
      key                       = local.clients_by_key[key].key
      name                      = local.clients_by_key[key].name
      client_id                 = random_string.client_id[key].result
      client_secret             = local.clients_by_key[key].is_public ? null : random_password.client_secret[key].result
      is_public                 = local.clients_by_key[key].is_public
      grant_types               = local.clients_by_key[key].grant_types
      redirect_uris             = local.clients_by_key[key].redirect_uris
      post_logout_redirect_uris = local.clients_by_key[key].post_logout_redirect_uris
      scope                     = local.clients_by_key[key].scope
      skip_consent              = local.clients_by_key[key].skip_consent
    }
  }
}

output "trusted_client_ids" {
  description = "Comma-separated client IDs whose managed definition skips consent, ordered by client key."
  sensitive   = true
  value = join(",", [
    for key in sort(keys(local.clients_by_key)) : random_string.client_id[key].result
    if local.clients_by_key[key].skip_consent
  ])
}

output "service_client_ids" {
  description = "Comma-separated client IDs allowed to use client_credentials, ordered by client key."
  sensitive   = true
  value = join(",", [
    for key in sort(keys(local.clients_by_key)) : random_string.client_id[key].result
    if contains(local.clients_by_key[key].grant_types, "client_credentials")
  ])
}
