locals {
  signal_runtime_ses_tag = {
    key   = "apollo_signal_managed"
    value = "true"
  }

  signal_runtime_ses_resources = {
    identities = [for region in sort(tolist(local.service_regions)) : "arn:${data.aws_partition.current.partition}:ses:${region}:${data.aws_caller_identity.current.account_id}:identity/*"]
    # Better Auth organization IDs use SES-compatible alphanumeric names but
    # do not carry a fixed prefix. SES appends an opaque tenant ID after the
    # caller-supplied tenant name. Ownership tags remain the authorization
    # boundary for reads and mutations after creation.
    tenants                  = [for region in sort(tolist(local.service_regions)) : "arn:${data.aws_partition.current.partition}:ses:${region}:${data.aws_caller_identity.current.account_id}:tenant/*/*"]
    shared_configuration_set = [for region in sort(tolist(local.service_regions)) : "arn:${data.aws_partition.current.partition}:ses:${region}:${data.aws_caller_identity.current.account_id}:configuration-set/${var.configuration_set_name}"]
  }

  signal_runtime_ses_tag_keys = [
    local.signal_runtime_ses_tag.key,
    "apollo_signal_kind",
  ]
}

locals {
  signal_runtime_policy_documents = {
    storage   = data.aws_iam_policy_document.runtime_storage.json
    messaging = data.aws_iam_policy_document.runtime_messaging.json
    ses       = data.aws_iam_policy_document.runtime_ses.json
  }
}

resource "aws_iam_user" "signal" {
  name = "${var.name_prefix}-signal"
  tags = var.tags
}

resource "aws_iam_policy" "signal_runtime" {
  for_each = local.signal_runtime_policy_documents

  name   = "${var.name_prefix}-signal-runtime-${each.key}"
  policy = each.value
  tags   = var.tags
}

resource "aws_iam_user_policy_attachment" "signal_runtime" {
  for_each = aws_iam_policy.signal_runtime

  user       = aws_iam_user.signal.name
  policy_arn = each.value.arn
}

resource "aws_iam_access_key" "signal" {
  user = aws_iam_user.signal.name
}
