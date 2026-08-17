variable "zone_id" {
  description = "Cloudflare zone ID that owns base_domain."
  type        = string
}

variable "base_domain" {
  description = "Base domain used to construct the three API hostnames."
  type        = string

  validation {
    condition     = can(regex("^(?:[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\\.)+[a-zA-Z]{2,63}$", var.base_domain))
    error_message = "base_domain must be a valid DNS domain."
  }
}

variable "origin_ipv4" {
  description = "Public IPv4 address of the nginx VPS origin."
  type        = string

  validation {
    condition = (
      can(cidrhost("${var.origin_ipv4}/32", 0)) &&
      !can(regex("^(?:(?:0|10|127)[.]|100[.](?:6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])[.]|169[.]254[.]|172[.](?:1[6-9]|2[0-9]|3[01])[.]|192[.](?:0[.](?:0|2)[.]|168[.])|198[.](?:1[89][.]|51[.]100[.])|203[.]0[.]113[.]|(?:22[4-9]|23[0-9]|24[0-9]|25[0-5])[.])", var.origin_ipv4))
    )
    error_message = "origin_ipv4 must be a globally routable unicast IPv4 address, not a private, loopback, link-local, documentation, multicast, or reserved address."
  }
}

variable "proxied" {
  description = "Whether Cloudflare proxies the API records."
  type        = bool
  default     = true
}

variable "enable_dmarc_ingestion" {
  type    = bool
  default = false
}

variable "ses_receiving_region" {
  type    = string
  default = "af-south-1"
}
