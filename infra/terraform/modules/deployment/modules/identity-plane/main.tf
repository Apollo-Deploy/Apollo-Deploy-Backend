module "oauth_clients" {
  source = "../../../docker/oauth-clients"

  clients = var.oauth_clients
}
