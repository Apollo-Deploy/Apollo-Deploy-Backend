terraform {
  required_providers {
    docker = {
      source  = "kreuzwerker/docker"
      version = "~> 3.0"
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
