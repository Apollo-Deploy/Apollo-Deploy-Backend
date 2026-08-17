# Consolidate the local Docker stack under the same deployment module used by
# the hosted root. These moves preserve every existing local Docker resource and
# OAuth credential; only their Terraform addresses change.
moved {
  from = module.oauth_clients
  to   = module.deployment.module.oauth_clients
}

moved {
  from = module.network
  to   = module.deployment.module.network
}

moved {
  from = module.infra
  to   = module.deployment.module.infra
}

moved {
  from = module.platform
  to   = module.deployment.module.platform
}

moved {
  from = module.billing
  to   = module.deployment.module.billing
}

moved {
  from = module.signal[0]
  to   = module.deployment.module.signal[0]
}
