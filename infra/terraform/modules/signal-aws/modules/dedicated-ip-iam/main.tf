locals {
  identity_arns                 = [for region in sort(tolist(var.regions)) : "arn:${var.partition}:ses:${region}:${var.account_id}:identity/*"]
  tenant_arns                   = [for region in sort(tolist(var.regions)) : "arn:${var.partition}:ses:${region}:${var.account_id}:tenant/org_*/*"]
  shared_configuration_set_arns = [for region in sort(tolist(var.regions)) : "arn:${var.partition}:ses:${region}:${var.account_id}:configuration-set/${var.shared_configuration_set_name}"]
  configuration_set_arns        = [for region in sort(tolist(var.regions)) : "arn:${var.partition}:ses:${region}:${var.account_id}:configuration-set/signal-dip-cfg-*"]
  pool_arns                     = [for region in sort(tolist(var.regions)) : "arn:${var.partition}:ses:${region}:${var.account_id}:dedicated-ip-pool/signal-dip-*"]
  ownership_tag_keys            = [var.ownership_tag.key, "apollo_signal_kind"]
}

data "aws_iam_policy_document" "configuration_sets" {
  statement {
    sid       = "CreateOwnedDedicatedIpConfigurationSets"
    actions   = ["ses:CreateConfigurationSet"]
    resources = local.configuration_set_arns

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/${var.ownership_tag.key}"
      values   = [var.ownership_tag.value]
    }

    condition {
      test     = "ForAllValues:StringEquals"
      variable = "aws:TagKeys"
      values   = local.ownership_tag_keys
    }
  }

  statement {
    sid = "ReadOwnedDedicatedIpConfigurationSets"
    actions = [
      "ses:GetConfigurationSetEventDestinations",
    ]
    resources = concat(
      local.shared_configuration_set_arns,
      local.configuration_set_arns,
    )

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/${var.ownership_tag.key}"
      values   = [var.ownership_tag.value]
    }
  }

  statement {
    sid = "MutateOwnedDedicatedIpConfigurationSets"
    actions = [
      "ses:CreateConfigurationSetEventDestination",
      "ses:DeleteConfigurationSet",
      "ses:UpdateConfigurationSetEventDestination",
    ]
    resources = local.configuration_set_arns

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/${var.ownership_tag.key}"
      values   = [var.ownership_tag.value]
    }
  }

  statement {
    sid       = "BindOwnedDedicatedIpPools"
    actions   = ["ses:PutConfigurationSetDeliveryOptions"]
    resources = concat(local.configuration_set_arns, local.pool_arns)

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/${var.ownership_tag.key}"
      values   = [var.ownership_tag.value]
    }
  }

  statement {
    sid       = "TagOwnedDedicatedIpResources"
    actions   = ["ses:TagResource"]
    resources = concat(local.configuration_set_arns, local.pool_arns)

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/${var.ownership_tag.key}"
      values   = [var.ownership_tag.value]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/${var.ownership_tag.key}"
      values   = [var.ownership_tag.value]
    }

    condition {
      test     = "ForAllValues:StringEquals"
      variable = "aws:TagKeys"
      values   = local.ownership_tag_keys
    }
  }

  statement {
    sid       = "SendWithOwnedDedicatedIpConfigurationSets"
    actions   = ["ses:SendEmail"]
    resources = concat(local.identity_arns, local.configuration_set_arns)

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/${var.ownership_tag.key}"
      values   = [var.ownership_tag.value]
    }
  }
}

data "aws_iam_policy_document" "pools_and_tenants" {
  statement {
    sid       = "CreateOwnedDedicatedIpPools"
    actions   = ["ses:CreateDedicatedIpPool"]
    resources = local.pool_arns

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/${var.ownership_tag.key}"
      values   = [var.ownership_tag.value]
    }

    condition {
      test     = "ForAllValues:StringEquals"
      variable = "aws:TagKeys"
      values   = local.ownership_tag_keys
    }
  }

  statement {
    sid = "ReadOwnedDedicatedIpPools"
    actions = [
      "ses:GetDedicatedIpPool",
      "ses:GetDedicatedIps",
    ]
    resources = local.pool_arns

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/${var.ownership_tag.key}"
      values   = [var.ownership_tag.value]
    }
  }

  statement {
    sid       = "DeleteOwnedDedicatedIpPools"
    actions   = ["ses:DeleteDedicatedIpPool"]
    resources = local.pool_arns

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/${var.ownership_tag.key}"
      values   = [var.ownership_tag.value]
    }
  }

  statement {
    sid = "AssociateOwnedDedicatedIpResources"
    actions = [
      "ses:CreateTenantResourceAssociation",
      "ses:DeleteTenantResourceAssociation",
    ]
    resources = concat(local.tenant_arns, local.configuration_set_arns)

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/${var.ownership_tag.key}"
      values   = [var.ownership_tag.value]
    }
  }
}

locals {
  dedicated_ip_policy_documents = {
    configuration-sets = data.aws_iam_policy_document.configuration_sets.json
    pools-and-tenants  = data.aws_iam_policy_document.pools_and_tenants.json
  }
}

resource "aws_iam_policy" "this" {
  for_each = local.dedicated_ip_policy_documents

  name   = "${var.name_prefix}-signal-dedicated-ip-${each.key}"
  policy = each.value

  tags = var.tags
}

resource "aws_iam_user_policy_attachment" "this" {
  for_each = aws_iam_policy.this

  user       = var.runtime_user_name
  policy_arn = each.value.arn
}
