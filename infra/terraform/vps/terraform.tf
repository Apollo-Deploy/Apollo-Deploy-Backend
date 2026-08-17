terraform {
  required_version = "~> 1.15.0"

  # Hosted state contains application secrets and the Signal IAM access-key
  # secret. Configure this required, encrypted remote backend with
  # `terraform init -backend-config=backend.hcl`.
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
    docker = {
      source  = "kreuzwerker/docker"
      version = "~> 3.9.0"
    }
  }
}

locals {
  allowed_aws_account_ids = [var.aws.account_id]

  # The Docker provider shells out to OpenSSH. Production must use the
  # operator-verified default known_hosts; an unknown or changed key fails.
  docker_ssh_options = [
    "-i",
    pathexpand(var.server.ssh_key_path),
    "-o",
    "BatchMode=yes",
    "-o",
    "StrictHostKeyChecking=yes",
  ]
}

provider "aws" {
  region              = var.aws.region
  allowed_account_ids = local.allowed_aws_account_ids
}

# Authentication is intentionally read from CLOUDFLARE_API_TOKEN so the token
# is not passed through Terraform variables or stored in state.
provider "cloudflare" {}

provider "docker" {
  host     = "ssh://${var.server.user}@${var.server.host}:${var.server.ssh_port}"
  ssh_opts = local.docker_ssh_options

  registry_auth {
    address  = "ghcr.io"
    username = var.registry_credentials.username
    password = var.registry_credentials.token
  }
}
