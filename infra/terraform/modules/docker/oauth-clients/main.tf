locals {
  clients_by_key = {
    for client in var.clients : client.key => client
  }
}

# These resources intentionally have no keepers. Configuration changes update the
# managed database record without silently rotating credentials. Rotate a client
# ID, secret, or record ID explicitly with Terraform's -replace option.
resource "random_string" "client_id" {
  for_each = local.clients_by_key

  length      = 32
  lower       = true
  upper       = true
  numeric     = false
  special     = false
  min_lower   = 1
  min_upper   = 1
  min_numeric = 0
  min_special = 0
}

resource "random_password" "client_secret" {
  for_each = {
    for key, client in local.clients_by_key : key => client
    if !client.is_public
  }

  length      = 64
  lower       = true
  upper       = true
  numeric     = true
  special     = false
  min_lower   = 1
  min_upper   = 1
  min_numeric = 1
  min_special = 0
}

resource "random_uuid" "record_id" {
  for_each = local.clients_by_key
}
