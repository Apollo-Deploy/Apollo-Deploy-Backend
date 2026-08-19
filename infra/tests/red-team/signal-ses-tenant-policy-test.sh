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

legacy_policy="$policy_root/legacy-ses-iam.tf"
grep -Fq 'identity/mail.apollodeploy.com' "$legacy_policy" || {
  echo 'FAIL: The verified legacy Signal identity is absent from the IAM exception.' >&2
  exit 1
}

if grep -Fq ':identity/*' "$legacy_policy"; then
  echo 'FAIL: The legacy identity exception was broadened beyond the verified identity.' >&2
  exit 1
fi

echo 'Signal SES tenant IAM policy test passed.'
