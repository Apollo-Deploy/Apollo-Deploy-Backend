output "container_name" {
  description = "Name of the PostgreSQL backup container."
  value       = docker_container.backup.name
}

output "backup_volume_name" {
  description = "Name of the durable Docker volume containing PostgreSQL backup files."
  value       = docker_volume.backups.name
}
output "offsite_container_name" {
  value       = try(docker_container.offsite[0].name, null)
  description = "Encrypted restic uploader container when offsite backup is configured."
}
