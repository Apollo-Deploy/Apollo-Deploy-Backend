data "aws_iam_policy_document" "runtime_ses" {
  statement {
    sid       = "ProbeSignalSESAccount"
    actions   = ["ses:GetAccount"]
    resources = ["*"]
  }

  statement {
    sid       = "ReadSignalEmailIdentities"
    actions   = ["ses:GetEmailIdentity"]
    resources = local.signal_runtime_ses_resources.identities

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/${local.signal_runtime_ses_tag.key}"
      values   = [local.signal_runtime_ses_tag.value]
    }
  }

  statement {
    sid       = "CreateOwnedSignalEmailIdentities"
    actions   = ["ses:CreateEmailIdentity"]
    resources = local.signal_runtime_ses_resources.identities

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/${local.signal_runtime_ses_tag.key}"
      values   = [local.signal_runtime_ses_tag.value]
    }

    condition {
      test     = "ForAllValues:StringEquals"
      variable = "aws:TagKeys"
      values   = local.signal_runtime_ses_tag_keys
    }
  }

  statement {
    sid = "MutateOwnedSignalEmailIdentities"
    actions = [
      "ses:DeleteEmailIdentity",
      "ses:PutEmailIdentityMailFromAttributes",
    ]
    resources = local.signal_runtime_ses_resources.identities

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/${local.signal_runtime_ses_tag.key}"
      values   = [local.signal_runtime_ses_tag.value]
    }
  }

  statement {
    sid       = "ReadOwnedSignalTenants"
    actions   = ["ses:GetTenant", "ses:ListTenantResources"]
    resources = local.signal_runtime_ses_resources.tenants

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/${local.signal_runtime_ses_tag.key}"
      values   = [local.signal_runtime_ses_tag.value]
    }
  }

  statement {
    sid       = "CreateOwnedSignalTenants"
    actions   = ["ses:CreateTenant"]
    resources = local.signal_runtime_ses_resources.tenants

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/${local.signal_runtime_ses_tag.key}"
      values   = [local.signal_runtime_ses_tag.value]
    }

    condition {
      test     = "ForAllValues:StringEquals"
      variable = "aws:TagKeys"
      values   = local.signal_runtime_ses_tag_keys
    }
  }

  statement {
    sid       = "DeleteOwnedSignalTenants"
    actions   = ["ses:DeleteTenant"]
    resources = local.signal_runtime_ses_resources.tenants

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/${local.signal_runtime_ses_tag.key}"
      values   = [local.signal_runtime_ses_tag.value]
    }
  }

  statement {
    sid     = "AssociateOwnedSignalTenantResources"
    actions = ["ses:CreateTenantResourceAssociation"]
    resources = concat(
      local.signal_runtime_ses_resources.identities,
      local.signal_runtime_ses_resources.shared_configuration_set,
      local.signal_runtime_ses_resources.tenants,
    )

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/${local.signal_runtime_ses_tag.key}"
      values   = [local.signal_runtime_ses_tag.value]
    }
  }

  statement {
    sid     = "DisassociateOwnedSignalTenantResources"
    actions = ["ses:DeleteTenantResourceAssociation"]
    resources = concat(
      local.signal_runtime_ses_resources.identities,
      local.signal_runtime_ses_resources.tenants,
    )

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/${local.signal_runtime_ses_tag.key}"
      values   = [local.signal_runtime_ses_tag.value]
    }
  }

  statement {
    sid     = "TagOwnedSignalSESResources"
    actions = ["ses:TagResource"]
    resources = concat(
      local.signal_runtime_ses_resources.identities,
      local.signal_runtime_ses_resources.tenants,
    )

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/${local.signal_runtime_ses_tag.key}"
      values   = [local.signal_runtime_ses_tag.value]
    }

    # Do not let a compromised runtime adopt an unrelated account resource by
    # applying Apollo's ownership tag and then exercising a tag-gated delete.
    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/${local.signal_runtime_ses_tag.key}"
      values   = [local.signal_runtime_ses_tag.value]
    }

    condition {
      test     = "ForAllValues:StringEquals"
      variable = "aws:TagKeys"
      values   = local.signal_runtime_ses_tag_keys
    }
  }

  statement {
    sid     = "SendFromSignalIdentities"
    actions = ["ses:SendEmail"]
    resources = concat(
      local.signal_runtime_ses_resources.identities,
      local.signal_runtime_ses_resources.shared_configuration_set,
    )

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/${local.signal_runtime_ses_tag.key}"
      values   = [local.signal_runtime_ses_tag.value]
    }
  }
}
