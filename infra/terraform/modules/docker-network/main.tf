resource "docker_network" "apollo" {
  name = "apollo"

  labels {
    label = "managed-by"
    value = "terraform"
  }
}
