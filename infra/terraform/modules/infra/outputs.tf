output "postgres_container_name" {
  description = "Postgres container name (used in healthchecks and bootstrap)"
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
