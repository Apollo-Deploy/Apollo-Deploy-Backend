# ── Migration trigger ─────────────────────────────────────────────────────────
variable "migration_trigger" {
  description = "Change this value to force re-run of migrations and OAuth registration"
  type        = string
  default     = "initial"
}

# ── VPS / SSH ─────────────────────────────────────────────────────────────────
variable "vps_host" {
  description = "VPS IP address or hostname"
  type        = string
}

variable "vps_user" {
  description = "SSH user on the VPS (typically root or deploy)"
  type        = string
  default     = "root"
}

variable "vps_ssh_port" {
  description = "SSH port on the VPS"
  type        = number
  default     = 22
}

variable "vps_ssh_key_path" {
  description = "Local path to the SSH private key"
  type        = string
  default     = "~/.ssh/id_ed25519"
}

# ── GHCR ──────────────────────────────────────────────────────────────────────
variable "ghcr_registry" {
  description = "GHCR registry prefix (e.g. ghcr.io/apollo-deploy)"
  type        = string
  default     = "ghcr.io/apollo-deploy"
}

variable "ghcr_username" {
  description = "GitHub username for GHCR authentication"
  type        = string
}

variable "ghcr_token" {
  description = "GitHub personal access token (read:packages scope)"
  type        = string
  sensitive   = true
}

variable "image_tag" {
  description = "Docker image tag to deploy (e.g. latest, v1.2.3, sha-abc1234)"
  type        = string
  default     = "latest"
}

# ── Domain ────────────────────────────────────────────────────────────────────
variable "base_domain" {
  description = "Base domain for all services (e.g. apollodeploy.com)"
  type        = string
}

variable "letsencrypt_email" {
  description = "Email for Let's Encrypt certificate registration"
  type        = string
}

# ── Database ──────────────────────────────────────────────────────────────────
variable "db_user" {
  type    = string
  default = "postgres"
}

variable "db_password" {
  type      = string
  sensitive = true
}

variable "db_name" {
  type    = string
  default = "apollo_deploy_platform"
}

# ── Redis ─────────────────────────────────────────────────────────────────────
variable "redis_password" {
  type      = string
  sensitive = true
}

# ── Platform secrets ──────────────────────────────────────────────────────────
variable "session_secret" {
  type      = string
  sensitive = true
}

variable "auth_cookie_secret" {
  type      = string
  sensitive = true
}

variable "encryption_key" {
  type      = string
  sensitive = true
}

variable "kms_key_v1" {
  type      = string
  sensitive = true
}

variable "kms_root_key_b64" {
  type      = string
  sensitive = true
}

variable "token_enc_salt_b64" {
  type      = string
  sensitive = true
}

variable "internal_service_secret" {
  type      = string
  sensitive = true
}

# ── DB role passwords ─────────────────────────────────────────────────────────
variable "platform_app_db_pass" {
  type      = string
  sensitive = true
}

variable "billing_app_db_pass" {
  type      = string
  sensitive = true
}

variable "billing_superuser_db_pass" {
  type      = string
  sensitive = true
}

variable "signal_app_db_pass" {
  type      = string
  sensitive = true
}

variable "signal_superuser_db_pass" {
  type      = string
  sensitive = true
}

variable "platform_verifier_db_pass" {
  type      = string
  sensitive = true
}

# ── AWS ───────────────────────────────────────────────────────────────────────
variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "aws_access_key_id" {
  type      = string
  sensitive = true
  default   = ""
}

variable "aws_secret_access_key" {
  type      = string
  sensitive = true
  default   = ""
}

variable "aws_account_id" {
  type    = string
  default = ""
}

variable "sqs_webhook_queue_url" {
  type    = string
  default = ""
}

variable "sqs_scheduled_email_queue_url" {
  type    = string
  default = ""
}

variable "sqs_domain_verification_queue_url" {
  type    = string
  default = ""
}

# ── Template media (Cloudflare R2 / S3) ───────────────────────────────────────
variable "template_media_provider" {
  type    = string
  default = "r2"
}

variable "s3_template_media_bucket" {
  type    = string
  default = ""
}

variable "template_media_public_base_url" {
  type    = string
  default = ""
}

variable "r2_account_id" {
  type      = string
  sensitive = true
  default   = ""
}

variable "r2_access_key_id" {
  type      = string
  sensitive = true
  default   = ""
}

variable "r2_secret_access_key" {
  type      = string
  sensitive = true
  default   = ""
}

# ── Events / Webhooks ─────────────────────────────────────────────────────────
variable "events_signing_secret" {
  type      = string
  sensitive = true
  default   = ""
}

variable "signal_webhook_secret_key" {
  type      = string
  sensitive = true
  default   = ""
}

variable "signal_byok_secret_key" {
  type      = string
  sensitive = true
  default   = ""
}

variable "signal_byok_cfn_template_url" {
  type    = string
  default = ""
}

variable "signal_tracking_cname_target" {
  type    = string
  default = ""
}

# ── AI ────────────────────────────────────────────────────────────────────────
variable "koog_api_key" {
  type      = string
  sensitive = true
  default   = ""
}

# ── SMS ───────────────────────────────────────────────────────────────────────
variable "telnyx_api_key" {
  type      = string
  sensitive = true
  default   = ""
}

variable "telnyx_messaging_profile_id" {
  type    = string
  default = ""
}

# ── Billing / Polar ───────────────────────────────────────────────────────────
variable "polar_api_key" {
  type      = string
  sensitive = true
  default   = ""
}

variable "polar_webhook_secret" {
  type      = string
  sensitive = true
  default   = ""
}

# ── Observability ─────────────────────────────────────────────────────────────
variable "metrics_enabled" {
  type    = bool
  default = false
}
