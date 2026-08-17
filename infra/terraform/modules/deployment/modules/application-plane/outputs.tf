output "containers" {
  description = "Application-plane container names."
  value = {
    platform = module.platform.platform_container_name
    nginx    = module.platform.nginx_container_name
    signal   = try(module.signal[0].signal_container_name, "")
    billing  = module.billing.billing_container_name
  }
}

output "certificate_volumes" {
  description = "Durable TLS volume names, or empty strings when TLS persistence is absent."
  value = {
    certificates    = try(docker_volume.certificates[0].name, "")
    certbot_webroot = try(docker_volume.certbot_webroot[0].name, "")
  }
}

output "releases" {
  description = "Application releases actually selected by the service modules."
  value = {
    platform = module.platform.release
    signal   = try(module.signal[0].release, null)
    billing  = module.billing.release
  }
}
