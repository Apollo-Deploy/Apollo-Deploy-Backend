output "public_urls" {
  description = "Public Platform, Signal and Billing URLs."
  value       = local.public_urls
}

output "dns_records" {
  description = "Cloudflare-managed API DNS records."
  value       = module.cloudflare_dns.records
}

output "signal_aws" {
  description = "Non-secret AWS resources consumed by Signal."
  value = {
    account_id                   = module.signal_aws.account_id
    queue_urls                   = module.signal_aws.queue_urls
    buckets                      = module.signal_aws.bucket_names
    project_archives_kms_key_arn = module.signal_aws.project_archive_kms_key_arn
    configuration_set            = module.signal_aws.configuration_set_name
    event_topic_arn              = module.signal_aws.managed_event_topic_arn
    event_topic_arns             = module.signal_aws.event_topic_arns
    dmarc_inbound_topic_arn      = module.signal_aws.dmarc_inbound_topic_arn
  }
}

output "signal_runtime_credentials" {
  description = "Signal IAM credential material written only to a protected VPS runtime file."
  sensitive   = true
  value = {
    access_key_id     = module.signal_aws.access_key_id
    secret_access_key = module.signal_aws.secret_access_key
  }
}
