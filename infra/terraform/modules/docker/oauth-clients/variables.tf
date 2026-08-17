variable "clients" {
  description = "OAuth clients to manage, keyed in state by each stable client key."
  type = list(object({
    key                       = string
    name                      = string
    is_public                 = bool
    grant_types               = list(string)
    redirect_uris             = list(string)
    post_logout_redirect_uris = optional(list(string), [])
    scope                     = string
    skip_consent              = bool
  }))

  validation {
    condition     = length(var.clients) > 0
    error_message = "At least one OAuth client must be defined."
  }

  validation {
    condition     = length(distinct([for client in var.clients : client.key])) == length(var.clients)
    error_message = "Each OAuth client key must be unique."
  }

  validation {
    condition = alltrue([
      for client in var.clients :
      can(regex("^[a-z][a-z0-9_-]{0,63}$", client.key))
    ])
    error_message = "Client keys must be 1-64 characters, start with a lowercase letter, and contain only lowercase letters, digits, underscores, or hyphens."
  }

  validation {
    condition = alltrue([
      for client in var.clients :
      length(trimspace(client.name)) > 0 &&
      length(client.name) <= 255 &&
      !can(regex("[[:cntrl:]]", client.name))
    ])
    error_message = "Client names must be non-empty, at most 255 characters, and contain no control characters."
  }

  validation {
    condition = alltrue([
      for client in var.clients :
      length(client.grant_types) > 0 &&
      length(distinct(client.grant_types)) == length(client.grant_types) &&
      alltrue([
        for grant_type in client.grant_types :
        contains(["authorization_code", "client_credentials", "refresh_token"], grant_type)
      ])
    ])
    error_message = "grant_types must be a non-empty, duplicate-free list containing only authorization_code, client_credentials, or refresh_token."
  }

  validation {
    condition = alltrue([
      for client in var.clients :
      (!contains(client.grant_types, "refresh_token") || contains(client.grant_types, "authorization_code")) &&
      (!client.is_public || !contains(client.grant_types, "client_credentials"))
    ])
    error_message = "refresh_token requires authorization_code, and public clients cannot use client_credentials."
  }

  validation {
    condition = alltrue([
      for client in var.clients :
      (!contains(client.grant_types, "authorization_code") || length(client.redirect_uris) > 0) &&
      length(distinct(client.redirect_uris)) == length(client.redirect_uris) &&
      alltrue([
        for uri in client.redirect_uris :
        length(uri) <= 2048 && can(regex("^https?://[^[:space:]#]+$", uri))
      ])
    ])
    error_message = "Authorization-code clients require redirect_uris; every redirect URI must be unique, at most 2048 characters, absolute HTTP(S), and contain no fragment."
  }

  validation {
    condition = alltrue([
      for client in var.clients :
      (length(client.post_logout_redirect_uris) == 0 || contains(client.grant_types, "authorization_code")) &&
      length(distinct(client.post_logout_redirect_uris)) == length(client.post_logout_redirect_uris) &&
      alltrue([
        for uri in client.post_logout_redirect_uris :
        length(uri) <= 2048 && can(regex("^https?://[^[:space:]#]+$", uri))
      ])
    ])
    error_message = "Post-logout redirect URIs require authorization_code and must be unique, at most 2048 characters, absolute HTTP(S), and contain no fragment."
  }

  validation {
    condition = alltrue([
      for client in var.clients :
      length(client.scope) <= 4096 &&
      can(regex("^[A-Za-z0-9._~:/-]+( [A-Za-z0-9._~:/-]+)*$", client.scope)) &&
      length(distinct(split(" ", client.scope))) == length(split(" ", client.scope))
    ])
    error_message = "scope must be a duplicate-free, single-space-separated list of OAuth scope tokens no longer than 4096 characters."
  }
}
