output "network_name" {
  description = "Name of the shared Apollo Docker network"
  value       = docker_network.apollo.name
}

output "network_id" {
  description = "ID of the shared Apollo Docker network"
  value       = docker_network.apollo.id
}
