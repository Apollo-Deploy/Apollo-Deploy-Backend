terraform {
  required_version = ">= 1.10, < 2.0"

  required_providers {
    docker = {
      source  = "kreuzwerker/docker"
      version = "3.9.0"
    }
  }
}

resource "docker_network" "apollo" {
  name = "apollo"

  labels {
    label = "managed-by"
    value = "terraform"
  }
}
