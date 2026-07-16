output "billing_container_name" {
  description = "Billing service container name (reachable inside the apollo network)"
  value       = docker_container.billing.name
}
