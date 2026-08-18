# One-time ownership handoff: forget every host-local Docker object without
# deleting it. Compose adopts the same fixed network, container and volume names.
# Apply only from a reviewed saved plan whose changes contain no remote destroy.
removed {
  from = module.deployment

  lifecycle {
    destroy = false
  }
}

removed {
  from = terraform_data.expected_aws_account

  lifecycle {
    destroy = false
  }
}
