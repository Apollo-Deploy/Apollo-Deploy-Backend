locals {
  signal_runtime_ses_tag = {
    key   = "apollo_signal_managed"
    value = "true"
  }

  signal_runtime_ses_resources = {
    identities = [for region in sort(tolist(local.service_regions)) : "arn:${data.aws_partition.current.partition}:ses:${region}:${data.aws_caller_identity.current.account_id}:identity/*"]
    # Apollo organization IDs have the stable org_ prefix. SES appends an
    # opaque tenant ID after the caller-supplied tenant name.
    tenants                  = [for region in sort(tolist(local.service_regions)) : "arn:${data.aws_partition.current.partition}:ses:${region}:${data.aws_caller_identity.current.account_id}:tenant/org_*/*"]
    shared_configuration_set = [for region in sort(tolist(local.service_regions)) : "arn:${data.aws_partition.current.partition}:ses:${region}:${data.aws_caller_identity.current.account_id}:configuration-set/${var.configuration_set_name}"]
  }

  signal_runtime_ses_tag_keys = [
    local.signal_runtime_ses_tag.key,
    "apollo_signal_kind",
  ]
}

data "aws_iam_policy_document" "application" {
  source_policy_documents = [
    data.aws_iam_policy_document.runtime_storage.json,
    data.aws_iam_policy_document.runtime_messaging.json,
    data.aws_iam_policy_document.runtime_ses.json,
  ]
}

resource "aws_iam_user" "signal" {
  name = "${var.name_prefix}-signal"
  tags = var.tags
}

resource "aws_iam_user_policy" "signal" {
  name   = "${var.name_prefix}-signal-runtime"
  user   = aws_iam_user.signal.name
  policy = data.aws_iam_policy_document.application.json
}

resource "aws_iam_access_key" "signal" {
  user = aws_iam_user.signal.name
}
