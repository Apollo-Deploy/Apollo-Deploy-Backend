output "network_name" {
  description = "Shared Docker network name."
  value       = module.network.network_name
}

output "containers" {
  description = "Data-plane container names."
  value = {
    postgres       = module.infrastructure.postgres_container_name
    pgbouncer      = module.infrastructure.pgbouncer_container_name
    redis          = module.infrastructure.redis_container_name
    backup         = try(module.postgres_backup[0].container_name, "")
    backup_offsite = try(module.postgres_backup[0].offsite_container_name, "")
  }
}

output "volumes" {
  description = "Data-plane volume names."
  value = {
    postgres = module.infrastructure.postgres_volume_name
    redis    = module.infrastructure.redis_volume_name
    backups  = try(module.postgres_backup[0].backup_volume_name, "")
  }
}
