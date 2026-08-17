#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

hosted_paths=(
  "$REPO_ROOT/infra/setup.sh"
  "$REPO_ROOT/infra/scripts/bootstrap-vps.sh"
  "$REPO_ROOT/infra/scripts/setup-vps-tls.sh"
  "$REPO_ROOT/infra/scripts/reconcile-services.sh"
  "$REPO_ROOT/infra/terraform/vps/terraform.tf"
)

for hosted_path in "${hosted_paths[@]}"; do
  if ! grep -Fq 'StrictHostKeyChecking=yes' "$hosted_path"; then
    echo "FAIL: Hosted SSH path does not explicitly require strict host-key verification: $hosted_path" >&2
    exit 1
  fi
done

if grep -Ein \
  'StrictHostKeyChecking=(accept-new|no|off|ask)|UserKnownHostsFile=|GlobalKnownHostsFile=' \
  "${hosted_paths[@]}"; then
  echo 'FAIL: A hosted path weakens host-key trust or overrides the default OpenSSH known_hosts.' >&2
  exit 1
fi

if grep -En '(^|[^[:alnum:]_-])ssh-keyscan([^[:alnum:]_-]|$)' \
  "$REPO_ROOT/infra/setup.sh" \
  "$REPO_ROOT/infra/scripts/bootstrap-vps.sh" \
  "$REPO_ROOT/infra/scripts/setup-vps-tls.sh" \
  "$REPO_ROOT/infra/scripts/reconcile-services.sh"; then
  echo 'FAIL: Production scripts must not enroll an unverified network host key automatically.' >&2
  exit 1
fi

echo 'Hosted SSH host-key policy regression tests passed.'
