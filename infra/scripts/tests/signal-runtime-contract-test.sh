#!/usr/bin/env bash
# Terraform interpolation markers below are intentionally matched as literals.
# shellcheck disable=SC2016

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/../../.." && pwd)
SERVICE_MODULE="$REPO_ROOT/infra/terraform/modules/profiles/signal-api/modules/service/main.tf"
DEPLOYMENT_MODULE="$REPO_ROOT/infra/terraform/modules/deployment/main.tf"
CONFIG_LOADER="$REPO_ROOT/apollo-signal-api/src/main/kotlin/com/apollodeploy/signal/infrastructure/config/SignalConfigLoader.kt"

assert_contains() {
  local needle="$1" file="$2"
  grep -Fq -- "$needle" "$file" || {
    printf 'Expected %s to contain: %s\n' "$file" "$needle" >&2
    exit 1
  }
}

assert_absent() {
  local needle="$1" file="$2"
  if grep -Fq -- "$needle" "$file"; then
    printf 'Expected %s not to contain: %s\n' "$file" "$needle" >&2
    exit 1
  fi
}

assert_contains 'APOLLO_SIGNAL_SQS_SCHEDULED_EMAIL_QUEUE_URL=${var.aws.sqs_scheduled_email_url}' "$SERVICE_MODULE"
assert_absent 'APOLLO_SIGNAL_SQS_SCHEDULED_BROADCAST_QUEUE_URL' "$SERVICE_MODULE"
assert_absent 'APOLLO_SIGNAL_SQS_INBOUND_EMAIL_QUEUE_URL' "$SERVICE_MODULE"
assert_absent 'SIGNAL_BYOK_' "$SERVICE_MODULE"
assert_absent 'SIGNAL_TRACKING_CNAME_TARGET' "$SERVICE_MODULE"

assert_contains 'tracking_base_url              = var.signal.tracking_base_url != "" ? var.signal.tracking_base_url : local.public_urls.signal' "$DEPLOYMENT_MODULE"
assert_absent 'tracking_base_url                 = "https://signal.${local.base_domain}"' "$DEPLOYMENT_MODULE"
assert_contains '"apollo-signal.aws.sqs-scheduled-email-queue-url" to "APOLLO_SIGNAL_SQS_SCHEDULED_EMAIL_QUEUE_URL"' "$CONFIG_LOADER"
assert_contains '"apollo-signal.tracking-base-url" to "SIGNAL_TRACKING_BASE_URL"' "$CONFIG_LOADER"
assert_contains 'SIGNAL_TRACKING_CNAME_TARGET is unsupported until custom-hostname DNS and TLS are provisioned' "$CONFIG_LOADER"

echo "Signal runtime configuration contract tests passed."
