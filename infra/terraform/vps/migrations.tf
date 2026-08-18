# Legacy `environments/vps` addresses moved under the canonical deployment
# module. Keep these declarations indefinitely so older state snapshots can be
# upgraded without Terraform mistaking the same Docker objects for new ones.
#
# The retired bootstrap module contained only terraform_data orchestration
# markers and external data reads. They do not represent remote infrastructure,
# so they are intentionally not mapped here. Their removal from state must not
# be confused with deleting a database, volume, container, or cloud resource.

# The three legacy application docker_registry_image data sources intentionally
# have no destination. Production now consumes reviewed digest-qualified image
# references directly; forgetting data-only state has no remote side effect.

moved {
  from = module.network.docker_network.apollo
  to   = module.deployment.module.network.docker_network.apollo
}

moved {
  from = module.infra.docker_volume.postgres_data
  to   = module.deployment.docker_volume.postgres_data
}

moved {
  from = module.infra.docker_volume.redis_data
  to   = module.deployment.docker_volume.redis_data
}

moved {
  from = module.infra.data.docker_registry_image.postgres
  to   = module.deployment.module.infra.data.docker_registry_image.postgres
}

moved {
  from = module.infra.data.docker_registry_image.pgbouncer
  to   = module.deployment.module.infra.data.docker_registry_image.pgbouncer
}

moved {
  from = module.infra.data.docker_registry_image.redis
  to   = module.deployment.module.infra.data.docker_registry_image.redis
}

moved {
  from = module.infra.docker_image.postgres
  to   = module.deployment.module.infra.docker_image.postgres
}

moved {
  from = module.infra.docker_image.pgbouncer
  to   = module.deployment.module.infra.docker_image.pgbouncer
}

moved {
  from = module.infra.docker_image.redis
  to   = module.deployment.module.infra.docker_image.redis
}

moved {
  from = module.infra.docker_container.postgres
  to   = module.deployment.module.infra.docker_container.postgres
}

moved {
  from = module.infra.docker_container.pgbouncer
  to   = module.deployment.module.infra.docker_container.pgbouncer
}

moved {
  from = module.infra.docker_container.redis
  to   = module.deployment.module.infra.docker_container.redis
}

moved {
  from = module.platform.docker_volume.letsencrypt_certs
  to   = module.deployment.docker_volume.certificates
}

moved {
  from = module.platform.docker_volume.certbot_webroot
  to   = module.deployment.docker_volume.certbot_webroot
}

moved {
  from = module.platform.docker_image.platform
  to   = module.deployment.module.platform.docker_image.platform
}

moved {
  from = module.platform.data.docker_registry_image.nginx
  to   = module.deployment.module.platform.data.docker_registry_image.nginx
}

moved {
  from = module.platform.data.docker_registry_image.certbot
  to   = module.deployment.module.platform.data.docker_registry_image.certbot
}

moved {
  from = module.platform.docker_image.nginx
  to   = module.deployment.module.platform.docker_image.nginx
}

moved {
  from = module.platform.docker_image.certbot
  to   = module.deployment.module.platform.docker_image.certbot
}

moved {
  from = module.platform.docker_container.platform
  to   = module.deployment.module.platform.docker_container.platform
}

moved {
  from = module.platform.docker_container.nginx
  to   = module.deployment.module.platform.docker_container.nginx
}

moved {
  from = module.platform.docker_container.certbot
  to   = module.deployment.module.platform.docker_container.certbot
}

moved {
  from = module.signal.docker_image.signal
  to   = module.deployment.module.signal[0].docker_image.signal
}

moved {
  from = module.signal.docker_container.signal
  to   = module.deployment.module.signal[0].docker_container.signal
}

moved {
  from = module.billing.docker_image.billing
  to   = module.deployment.module.billing.docker_image.billing
}

moved {
  from = module.billing.docker_container.billing
  to   = module.deployment.module.billing.docker_container.billing
}
