terraform {
  required_version = "~> 1.15.0"

  backend "s3" {}

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5.21"
    }
    # Retained for one declarative state-handoff release. Remove these providers
    # after production has applied migrations.tf and the legacy module is absent
    # from state.
    docker = {
      source  = "kreuzwerker/docker"
      version = "~> 3.9.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.9.0"
    }
  }
}

provider "aws" {
  region              = var.aws.region
  allowed_account_ids = [var.aws.account_id]
}

# Authentication is read only from CLOUDFLARE_API_TOKEN so it never enters
# Terraform variables, plans or state.
provider "cloudflare" {}
