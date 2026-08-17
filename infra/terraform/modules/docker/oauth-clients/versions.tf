terraform {
  required_version = ">= 1.10, < 2.0"

  required_providers {
    random = {
      source  = "hashicorp/random"
      version = "3.9.0"
    }
  }
}
