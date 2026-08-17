output "billing_container_name" {
  description = "Billing service container name (reachable inside the apollo network)"
  value       = docker_container.billing.name
}

output "release" {
  description = "Billing image reference and source revision recorded on the service container."
  value = {
    image         = var.image
    source_commit = var.source_commit
  }
}
