output "public_urls" {
  value       = module.deployment.public_urls
  description = "Public Platform, Billing, and Signal API URLs."
}

output "containers" {
  value       = module.deployment.containers
  description = "Docker containers managed on the VPS."
}

output "durable_volumes" {
  value       = module.deployment.durable_volumes
  description = "Persistent Docker volumes protected from destroy."
}

output "release_manifest" {
  description = "Digest-pinned service images and audited source commits deployed to the VPS."
  value       = module.deployment.release_manifest
}

output "signal_aws" {
  description = "AWS resources consumed by Signal."
  value = {
    queue_urls = module.signal_aws.queue_urls
    buckets    = module.signal_aws.bucket_names
    project_archives = {
      bucket_arn               = module.signal_aws.project_archive_bucket_arn
      kms_key_arn              = module.signal_aws.project_archive_kms_key_arn
      support_restore_role_arn = module.signal_aws.support_restore_role_arn
    }
    ses = {
      configuration_set = module.signal_aws.configuration_set_name
      managed_topic     = module.signal_aws.managed_event_topic_arn
    }
  }
}

output "dns_records" {
  description = "Cloudflare-managed API DNS records."
  value       = module.cloudflare_dns.records
}

output "reconcile" {
  description = "Run the reconciliation script after Terraform applies this hosted stack."
  value       = module.deployment.reconcile
  sensitive   = true
}
