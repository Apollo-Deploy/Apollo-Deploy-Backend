terraform {
  required_version = ">= 1.10, < 2.0"

  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "5.23.0"
    }
  }
}

resource "cloudflare_dns_record" "api" {
  for_each = var.api_hosts

  zone_id = var.zone_id
  name    = each.value
  type    = "A"
  content = var.origin_ipv4
  proxied = var.proxied
  ttl     = var.proxied ? 1 : 300

  comment = "Apollo ${title(each.key)} API; managed by Terraform"
  tags    = ["managed-by:terraform", "service:${each.key}"]
}

resource "cloudflare_dns_record" "dmarc_mx" {
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

resource "cloudflare_dns_record" "dmarc_ses_verification" {
  zone_id = var.zone_id
  name    = "_amazonses.reports.${var.base_domain}"
  type    = "TXT"
  content = var.dmarc_ses_verification_token
  proxied = false
  ttl     = 300

  comment = "SES verification for the Signal DMARC receiver; managed by Terraform"
  tags    = ["managed-by:terraform", "service:signal", "purpose:dmarc"]
}

resource "cloudflare_dns_record" "dmarc_external_authorization" {
  zone_id = var.zone_id
  name    = "*._report._dmarc.reports.${var.base_domain}"
  type    = "TXT"
  content = "v=DMARC1"
  proxied = false
  ttl     = 300

  comment = "DMARC wildcard external-report authorization; managed by Terraform"
  tags    = ["managed-by:terraform", "service:signal", "purpose:dmarc"]
}
