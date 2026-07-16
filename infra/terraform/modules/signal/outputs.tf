output "signal_container_name" {
  description = "Signal service container name (reachable inside the apollo network)"
  value       = docker_container.signal.name
}
