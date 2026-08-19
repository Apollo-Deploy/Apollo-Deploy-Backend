#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
policy_root="$repo_root/infra/terraform/modules/signal-aws"

if ! find "$policy_root" -type f -name '*.tf' -exec grep -Fq 'tenant/*/*' {} +; then
  echo 'FAIL: Signal SES IAM policies exclude unprefixed Better Auth organization IDs.' >&2
  exit 1
fi

if find "$policy_root" -type f -name '*.tf' -exec grep -Fq 'tenant/org_*/*' {} +; then
  echo 'FAIL: A Signal SES IAM policy still assumes legacy org_-prefixed identifiers.' >&2
  exit 1
fi

runtime_ses_policy="$policy_root/runtime-ses-iam.tf"
send_statement="$(
  awk '
    /sid[[:space:]]*=[[:space:]]*"SendFromSignalIdentities"/ { in_send_statement = 1 }
    in_send_statement { print }
    in_send_statement && /^  }$/ { exit }
  ' "$runtime_ses_policy"
)"

if [[ "$send_statement" != *'actions = ["ses:SendEmail"]'* ]]; then
  echo 'FAIL: Signal runtime policy does not contain the expected SES send statement.' >&2
  exit 1
fi

if [[ "$send_statement" != *'local.signal_runtime_ses_resources.identities'* ]] \
  || [[ "$send_statement" != *'local.signal_runtime_ses_resources.shared_configuration_set'* ]]; then
  echo 'FAIL: Signal SES sends are not scoped to identity and configuration-set ARNs.' >&2
  exit 1
fi

if [[ "$send_statement" == *'condition {'* ]]; then
  echo 'FAIL: SES SendEmail must not depend on resource-tag context omitted by live SES authorization.' >&2
  exit 1
fi

echo 'Signal SES tenant IAM policy test passed.'
