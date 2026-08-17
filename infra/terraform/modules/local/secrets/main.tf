# =============================================================================
# Secrets module — generates ALL random passwords and IDs for Apollo Deploy.
# No variables needed: this module is self-contained. Call it once and pass
# its outputs to every other module that needs credentials.
# =============================================================================

terraform {
  required_version = ">= 1.10, < 2.0"

  required_providers {
    random = {
      source  = "hashicorp/random"
      version = "3.9.0"
    }
  }
}

# ── Passwords ─────────────────────────────────────────────────────────────────
resource "random_password" "db" {
  length  = 32
  special = false
}

resource "random_password" "redis" {
  length  = 32
  special = false
}

resource "random_password" "session" {
  length  = 48
  special = false
}

resource "random_password" "auth_cookie" {
  length  = 48
  special = false
}

resource "random_password" "internal" {
  length  = 32
  special = false
}

resource "random_password" "platform_app" {
  length  = 32
  special = false
}

resource "random_password" "billing_app" {
  length  = 32
  special = false
}

resource "random_password" "billing_super" {
  length  = 32
  special = false
}

resource "random_password" "signal_app" {
  length  = 32
  special = false
}

resource "random_password" "signal_super" {
  length  = 32
  special = false
}

resource "random_password" "platform_verifier" {
  length  = 32
  special = false
}
