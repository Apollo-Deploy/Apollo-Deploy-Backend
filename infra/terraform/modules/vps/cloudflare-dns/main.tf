terraform {
  required_version = ">= 1.10, < 2.0"

  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "5.23.0"
    }
  }
}

locals {
  api_services = toset(["billing", "platform", "signal"])
}

resource "cloudflare_dns_record" "api" {
  for_each = local.api_services

  zone_id = var.zone_id
  name    = "api.${each.key}.${var.base_domain}"
  type    = "A"
  content = var.origin_ipv4
  proxied = var.proxied
  ttl     = var.proxied ? 1 : 300

  comment = "Apollo ${title(each.key)} API; managed by Terraform"
  tags    = ["managed-by:terraform", "service:${each.key}"]
}

resource "cloudflare_dns_record" "dmarc_mx" {
  count = var.enable_dmarc_ingestion ? 1 : 0

  zone_id  = var.zone_id
  name     = "reports.${var.base_domain}"
  type     = "MX"
  content  = "inbound-smtp.${var.ses_receiving_region}.amazonaws.com"
  priority = 10
  proxied  = false
  ttl      = 300

  comment = "Signal DMARC aggregate-report receiver; managed by Terraform"
  tags    = ["managed-by:terraform", "service:signal", "purpose:dmarc"]
}

resource "cloudflare_dns_record" "dmarc_external_authorization" {
  count = var.enable_dmarc_ingestion ? 1 : 0

  zone_id = var.zone_id
  name    = "*._report._dmarc.reports.${var.base_domain}"
  type    = "TXT"
  content = "v=DMARC1"
  proxied = false
  ttl     = 300

  comment = "DMARC wildcard external-report authorization; managed by Terraform"
  tags    = ["managed-by:terraform", "service:signal", "purpose:dmarc"]
}
