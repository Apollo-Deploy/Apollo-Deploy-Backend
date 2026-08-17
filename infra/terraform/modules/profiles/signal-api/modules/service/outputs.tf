output "signal_container_name" {
  description = "Signal service container name (reachable inside the apollo network)"
  value       = docker_container.signal.name
}

output "release" {
  description = "Signal image reference and source revision recorded on the service container."
  value = {
    image         = var.image
    source_commit = var.source_commit
  }
}
