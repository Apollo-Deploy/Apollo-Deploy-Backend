output "postgres_container_name" {
  description = "Postgres container name (used by health checks and reconciliation)"
  value       = docker_container.postgres.name
}

output "pgbouncer_container_name" {
  description = "PgBouncer container name (platform API connects here)"
  value       = docker_container.pgbouncer.name
}

output "redis_container_name" {
  description = "Redis container name"
  value       = docker_container.redis.name
}

output "postgres_volume_name" {
  description = "Docker volume containing PostgreSQL data"
  value       = nonsensitive(local.postgres_volume_name)
}

output "redis_volume_name" {
  description = "Docker volume containing Redis append-only data"
  value       = nonsensitive(local.redis_volume_name)
}
