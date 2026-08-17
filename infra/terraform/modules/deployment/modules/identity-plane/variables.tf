variable "oauth_clients" {
  description = "Canonical OAuth clients managed for enabled Apollo services."
  type = list(object({
    key                       = string
    name                      = string
    is_public                 = bool
    grant_types               = list(string)
    redirect_uris             = list(string)
    post_logout_redirect_uris = list(string)
    scope                     = string
    skip_consent              = bool
  }))
}
