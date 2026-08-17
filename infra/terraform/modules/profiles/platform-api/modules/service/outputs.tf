output "platform_container_name" {
  description = "Platform API container name"
  value       = docker_container.platform.name
}

output "nginx_container_name" {
  description = "nginx container name"
  value       = docker_container.nginx.name
}

output "certbot_container_name" {
  description = "certbot container name"
  value       = docker_container.certbot.name
}

output "release" {
  description = "Platform image reference and source revision recorded on the service container."
  value = {
    image         = var.image
    source_commit = var.source_commit
  }
}
