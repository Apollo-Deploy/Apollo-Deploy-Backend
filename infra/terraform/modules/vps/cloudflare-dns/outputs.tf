output "records" {
  description = "Cloudflare-managed DNS records keyed by API service."
  value = {
    for service, record in cloudflare_dns_record.api : service => {
      id       = record.id
      hostname = record.name
      content  = record.content
      proxied  = record.proxied
    }
  }
}
