# The shared deployment module makes hosted-only resources conditional so the
# local root can reuse the same application stack without inheriting protected
# production storage and backup services. Preserve pre-consolidation VPS state.
moved {
  from = docker_volume.postgres_data
  to   = docker_volume.postgres_data[0]
}

moved {
  from = docker_volume.redis_data
  to   = docker_volume.redis_data[0]
}

moved {
  from = docker_volume.certificates
  to   = docker_volume.certificates[0]
}

moved {
  from = docker_volume.certbot_webroot
  to   = docker_volume.certbot_webroot[0]
}

moved {
  from = module.postgres_backup
  to   = module.postgres_backup[0]
}

moved {
  from = module.signal
  to   = module.signal[0]
}

# Lifecycle-plane split. These moves change only Terraform addresses; the
# Docker objects retain their existing names and provider identities.
moved {
  from = module.network
  to   = module.data_plane.module.network
}

moved {
  from = module.infra
  to   = module.data_plane.module.infrastructure
}

moved {
  from = docker_volume.postgres_data[0]
  to   = module.data_plane.docker_volume.postgres_data[0]
}

moved {
  from = docker_volume.redis_data[0]
  to   = module.data_plane.docker_volume.redis_data[0]
}

moved {
  from = module.postgres_backup[0]
  to   = module.data_plane.module.postgres_backup[0]
}

moved {
  from = module.oauth_clients
  to   = module.identity_plane.module.oauth_clients
}

moved {
  from = docker_volume.certificates[0]
  to   = module.application_plane.docker_volume.certificates[0]
}

moved {
  from = docker_volume.certbot_webroot[0]
  to   = module.application_plane.docker_volume.certbot_webroot[0]
}

moved {
  from = module.platform
  to   = module.application_plane.module.platform
}

moved {
  from = module.signal[0]
  to   = module.application_plane.module.signal[0]
}

moved {
  from = module.billing
  to   = module.application_plane.module.billing
}
