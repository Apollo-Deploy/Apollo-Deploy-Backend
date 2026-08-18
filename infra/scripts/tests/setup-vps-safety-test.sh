#!/usr/bin/env bash

# This test sources setup.sh as a library and replaces selected globals and
# functions dynamically inside subshells; ShellCheck cannot follow those
# indirect calls across the sourced boundary.
# shellcheck disable=SC1091,SC2030,SC2031,SC2034,SC2329

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
SETUP_SCRIPT="$REPO_ROOT/infra/setup.sh"
MIGRATIONS_FILE="$REPO_ROOT/infra/terraform/vps/migrations.tf"

APOLLO_SETUP_LIBRARY_ONLY=true
# shellcheck source=../../setup.sh
source "$SETUP_SCRIPT"

# The inventory helpers expand these values before the fake ssh function runs.
VPS_PORT=22
VPS_KEY_EXPANDED=/tmp/apollo-setup-test-key
VPS_USER=deploy
VPS_HOST=203.0.113.10

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_contains() {
  local expected="$1"
  local actual="$2"
  case "$actual" in
    *"$expected"*) ;;
    *) fail "Expected output to contain '$expected', got: $actual" ;;
  esac
}

valid_ipv4 1.1.1.1 || fail 'A globally routable IPv4 address was rejected.'
for reserved_ipv4 in 0.0.0.0 10.0.0.1 100.64.0.1 127.0.0.1 169.254.1.1 \
  172.16.0.1 192.0.2.1 192.168.1.1 198.18.0.1 198.51.100.1 \
  203.0.113.1 224.0.0.1 240.0.0.1 255.255.255.255; do
  if valid_ipv4 "$reserved_ipv4"; then
    fail "Reserved/non-routable VPS origin passed validation: $reserved_ipv4"
  fi
done

allowed_move_count=0
while IFS= read -r source_address; do
  [ -n "$source_address" ] || continue
  is_allowed_legacy_vps_address "$source_address" \
    || fail "migrations.tf source is missing from the wizard allowlist: $source_address"
  allowed_move_count=$((allowed_move_count + 1))
done < <(sed -n 's/^[[:space:]]*from = //p' "$MIGRATIONS_FILE")
[ "$allowed_move_count" -eq 26 ] \
  || fail "Expected 26 reviewed moved sources, found $allowed_move_count."
for retired_data_source in platform signal billing; do
  if is_allowed_legacy_vps_address "data.docker_registry_image.$retired_data_source"; then
    fail "A deliberately forgotten app registry data source remained in the exact moved-source allowlist."
  fi
  is_reviewed_forgotten_legacy_vps_address "data.docker_registry_image.$retired_data_source" \
    || fail "A safe data-only state disposition was not reviewed explicitly."
done
if is_allowed_legacy_vps_address 'module.bootstrap.terraform_data.wait_postgres'; then
  fail 'An unmoved legacy bootstrap address was accepted.'
fi

(
  config_test_root="$(mktemp -d "${TMPDIR:-/tmp}/apollo-setup-config-test.XXXXXX")"
  trap 'rm -r -- "$config_test_root"' EXIT
  VPS_ROOT="$config_test_root"
  VPS_STATE_LIST=""
  printf '%s\n' 'existing-active-config' >"$VPS_ROOT/terraform.tfvars"
  : >"$config_test_root/test-key"
  chmod 600 "$config_test_root/test-key"

  process_secret_sentinel='apollo-process-secret-sentinel-73c2044f'
  real_python="$(command -v python3)"
  fake_bin="$config_test_root/fake-bin"
  mkdir -p "$fake_bin"
  cat >"$fake_bin/python3" <<'PYTHON_WRAPPER'
#!/usr/bin/env bash
set -euo pipefail

secret_sentinel='apollo-process-secret-sentinel-73c2044f'
environment_snapshot="$(env)"
case "$environment_snapshot" in
  *"$secret_sentinel"*)
    echo 'tfvars secret leaked through the renderer environment' >&2
    exit 91
    ;;
esac
for argument in "$@"; do
  case "$argument" in
    *"$secret_sentinel"*)
      echo 'tfvars secret leaked through the renderer argv' >&2
      exit 92
      ;;
  esac
done
for proc_file in "/proc/$$/cmdline" "/proc/$$/environ" "/proc/$PPID/cmdline" "/proc/$PPID/environ"; do
  [ -r "$proc_file" ] || continue
  proc_snapshot="$(tr '\000' '\n' <"$proc_file")"
  case "$proc_snapshot" in
    *"$secret_sentinel"*)
      echo "tfvars secret was observable in $proc_file" >&2
      exit 93
      ;;
  esac
done
exec "$APOLLO_TEST_REAL_PYTHON" "$@"
PYTHON_WRAPPER
  chmod 700 "$fake_bin/python3"
  APOLLO_TEST_REAL_PYTHON="$real_python"
  export APOLLO_TEST_REAL_PYTHON
  PATH="$fake_bin:$PATH"
  export PATH

  confirm() {
    case "$1" in
      'Reuse existing VPS configuration?') return 1 ;;
      *) return 0 ;;
    esac
  }
  prompt() {
    case "$1" in
      'SSH private key') ANSWER="$config_test_root/test-key" ;;
      'Signal supported AWS regions (comma-separated or all)') ANSWER='af-south-1' ;;
      *) ANSWER="$2" ;;
    esac
  }
  prompt_secret() {
    ANSWER="$process_secret_sentinel"
  }
  prompt_valid() {
    case "$1" in
      'VPS hostname or IPv4') ANSWER='203.0.113.10' ;;
      'SSH user') ANSWER='deploy' ;;
      'SSH port') ANSWER='22' ;;
      'Base domain') ANSWER='example.com' ;;
      "Let's Encrypt email") ANSWER='ops@example.com' ;;
      'Cloudflare zone ID') ANSWER='0123456789abcdef0123456789abcdef' ;;
      'VPS public IPv4') ANSWER='1.1.1.1' ;;
      'GHCR registry path') ANSWER='ghcr.io/apollo-deploy' ;;
      'GHCR user') ANSWER='apollo-test' ;;
      'Platform image digest') ANSWER='sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' ;;
      'Platform source commit') ANSWER='1111111111111111111111111111111111111111' ;;
      'Signal image digest') ANSWER='sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' ;;
      'Signal source commit') ANSWER='2222222222222222222222222222222222222222' ;;
      'Billing image digest') ANSWER='sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc' ;;
      'Billing source commit') ANSWER='3333333333333333333333333333333333333333' ;;
      'Signal primary AWS region') ANSWER='af-south-1' ;;
      'Expected AWS account ID') ANSWER='123456789012' ;;
      'Operator alert SNS topic ARN') ANSWER='arn:aws:sns:af-south-1:123456789012:apollo-test-ops-alerts' ;;
      *) return 1 ;;
    esac
  }
  random_hex() { printf '%s\n' "$process_secret_sentinel"; }
  select_approved_release() {
    APPROVED_RELEASE_JSON='{
      "platform":{"image":"ghcr.io/apollo-deploy/apollo-platform-api@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","source_commit":"1111111111111111111111111111111111111111"},
      "signal":{"image":"ghcr.io/apollo-deploy/apollo-signal-api@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","source_commit":"2222222222222222222222222222222222222222"},
      "billing":{"image":"ghcr.io/apollo-deploy/apollo-billing-api@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc","source_commit":"3333333333333333333333333333333333333333"}
    }'
  }

  write_vps_config
  [ "$VPS_CONFIG_COMMIT_REQUIRED" = true ]
  [ "$VPS_VAR_FILE" = "$VPS_CONFIG_CANDIDATE" ]
  [ -f "$VPS_CONFIG_CANDIDATE" ]
  candidate_mode="$(stat -c '%a' "$VPS_CONFIG_CANDIDATE" 2>/dev/null || stat -f '%Lp' "$VPS_CONFIG_CANDIDATE")"
  [ "$candidate_mode" = 600 ]
  [ "$(cat "$VPS_ROOT/terraform.tfvars")" = 'existing-active-config' ]
  grep -Fq 'account_id = "123456789012"' "$VPS_CONFIG_CANDIDATE"
  grep -Fq 'operator_alert_topic_arn = "arn:aws:sns:af-south-1:123456789012:apollo-test-ops-alerts"' "$VPS_CONFIG_CANDIDATE"
  grep -Fq "token    = \"$process_secret_sentinel\"" "$VPS_CONFIG_CANDIDATE"
  grep -Fq "session_secret          = \"$process_secret_sentinel\"" "$VPS_CONFIG_CANDIDATE"
  grep -Fq 'apollo-platform-api@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' "$VPS_CONFIG_CANDIDATE"
  grep -Fq 'source_commit = "3333333333333333333333333333333333333333"' "$VPS_CONFIG_CANDIDATE"
  if grep -Fq 'tag =' "$VPS_CONFIG_CANDIDATE"; then
    fail 'The generated production configuration still follows a movable image tag.'
  fi

  read_vps_state_list() { VPS_STATE_LIST=""; }
  ssh() { :; }
  guard_vps_state_against_brownfield_docker
  commit_vps_config
  [ "$VPS_VAR_FILE" = "$VPS_ROOT/terraform.tfvars" ]
  [ "$VPS_CONFIG_COMMIT_REQUIRED" = false ]
  grep -Fq 'environment = "production"' "$VPS_ROOT/terraform.tfvars"
  grep -FRqx 'existing-active-config' "$VPS_ROOT/.setup-backups"

  cleanup_candidate="$VPS_ROOT/.cleanup-candidate"
  : >"$cleanup_candidate"
  VPS_CONFIG_CANDIDATE="$cleanup_candidate"
  PLAN_FILE=""
  cleanup
  [ ! -e "$cleanup_candidate" ]
) || fail 'VPS configuration was not staged, gated, committed, and cleaned up safely.'

missing_active_output="$({
  (
    missing_config_root="$(mktemp -d "${TMPDIR:-/tmp}/apollo-setup-missing-config-test.XXXXXX")"
    trap 'rm -r -- "$missing_config_root"' EXIT
    VPS_ROOT="$missing_config_root"
    VPS_STATE_LIST='module.deployment.docker_volume.postgres_data[0]'
    write_vps_config
  )
} 2>&1)" && fail 'Non-empty VPS state was allowed to generate replacement credentials.'
assert_contains 'terraform.tfvars is missing' "$missing_active_output"

(
  VPS_HOST=host.example.com
  VPS_PORT=2222
  VPS_USER=deploy
  VPS_SSH_ARGS=(
    -p "$VPS_PORT"
    -i /tmp/apollo-setup-test-key
    -o BatchMode=yes
    -o StrictHostKeyChecking=yes
  )
  ssh() {
    case " $* " in
      *' -o StrictHostKeyChecking=yes '*) ;;
      *) return 1 ;;
    esac
    case " $* " in
      *StrictHostKeyChecking=accept-new*|*StrictHostKeyChecking=no*) return 1 ;;
    esac
  }
  verify_ssh
) || fail 'The VPS connection preflight did not enforce strict host-key checking.'

strict_ssh_failure="$({
  (
    VPS_HOST=host.example.com
    VPS_PORT=2222
    VPS_USER=deploy
    VPS_SSH_ARGS=(-p "$VPS_PORT" -o StrictHostKeyChecking=yes)
    ssh() { return 1; }
    verify_ssh
  )
} 2>&1)" && fail 'A failed strict SSH connection preflight was accepted.'
assert_contains '[host.example.com]:2222' "$strict_ssh_failure"
assert_contains 'Verify the server fingerprint' "$strict_ssh_failure"

(
  backend_fixture="$(mktemp "${TMPDIR:-/tmp}/apollo-backend-config.XXXXXX")"
  trap 'rm -f -- "$backend_fixture"' EXIT
  cat > "$backend_fixture" <<'BACKEND'
# apollo_expected_account_id = "123456789012"
# apollo_deployment_id = "0123456789abcdef0123456789abcdef"
# apollo_state_lineage = "unbound"
# apollo_target_sha256 = "unbound"
bucket       = "apollo-state-test"
key          = "apollo/vps/terraform.tfstate"
region       = "af-south-1"
encrypt      = true
use_lockfile = true
allowed_account_ids = ["123456789012"]
BACKEND
  read_backend_config "$backend_fixture"
  [ "$BACKEND_BUCKET" = apollo-state-test ]
  [ "$BACKEND_REGION" = af-south-1 ]
  [ "$BACKEND_EXPECTED_ACCOUNT_ID" = 123456789012 ]
) || fail 'A literal account-bound backend configuration was not parsed safely.'

for unsafe_backend in encryption lockfile credentials endpoint profile; do
  (
    backend_fixture="$(mktemp "${TMPDIR:-/tmp}/apollo-unsafe-backend.XXXXXX")"
    trap 'rm -f -- "$backend_fixture"' EXIT
    encrypt_value=true
    lockfile_value=true
    [ "$unsafe_backend" != encryption ] || encrypt_value=false
    [ "$unsafe_backend" != lockfile ] || lockfile_value=false
    {
      printf '%s\n' \
        '# apollo_expected_account_id = "123456789012"' \
        '# apollo_deployment_id = "0123456789abcdef0123456789abcdef"' \
        '# apollo_state_lineage = "unbound"' \
        '# apollo_target_sha256 = "unbound"' \
        'bucket = "apollo-state-test"' \
        'key = "apollo/vps/terraform.tfstate"' \
        'region = "af-south-1"'
      printf 'encrypt = %s\nuse_lockfile = %s\n' "$encrypt_value" "$lockfile_value"
      printf '%s\n' 'allowed_account_ids = ["123456789012"]'
      [ "$unsafe_backend" != credentials ] \
        || printf '%s\n' 'access_key = "must-not-be-stored-here"'
      [ "$unsafe_backend" != endpoint ] \
        || printf '%s\n' 'endpoints = { s3 = "https://state.invalid" }'
      [ "$unsafe_backend" != profile ] \
        || printf '%s\n' 'profile = "unverified-backend-profile"'
    } > "$backend_fixture"
    read_backend_config "$backend_fixture"
  ) >/dev/null 2>&1 \
    && fail "Unsafe backend configuration '$unsafe_backend' was accepted."
done

(
  BACKEND_EXPECTED_ACCOUNT_ID=123456789012
  SIGNAL_AWS_ACCOUNT_ID=123456789012
  verify_aws_account_boundary
) || fail 'Matching state and Signal AWS account boundaries were rejected.'
if (
  BACKEND_EXPECTED_ACCOUNT_ID=123456789012
  SIGNAL_AWS_ACCOUNT_ID=999999999999
  verify_aws_account_boundary
) >/dev/null 2>&1; then
  fail 'A cross-account backend/application split passed the single-credential wizard boundary.'
fi

for endpoint_variable in \
  AWS_ENDPOINT_URL \
  AWS_ENDPOINT_URL_S3 \
  AWS_S3_ENDPOINT \
  AWS_ENDPOINT_URL_STS \
  AWS_STS_ENDPOINT; do
  if (
    export "$endpoint_variable=https://state-redirect.example.invalid"
    verify_aws_endpoint_policy
  ) >/dev/null 2>&1; then
    fail "AWS endpoint override '$endpoint_variable' passed the backend trust boundary."
  fi
done
(
  unset AWS_IGNORE_CONFIGURED_ENDPOINT_URLS
  verify_aws_endpoint_policy
  [ "$AWS_IGNORE_CONFIGURED_ENDPOINT_URLS" = true ]
) || fail 'Shared AWS profile endpoint overrides were not disabled.'

terraform_context_root="$(mktemp -d "${TMPDIR:-/tmp}/apollo-terraform-context.XXXXXX")"
mkdir -p "$terraform_context_root/.terraform"
for unsafe_variable in \
  TF_WORKSPACE \
  TF_DATA_DIR \
  TF_CLI_CONFIG_FILE \
  TF_CLI_ARGS \
  TF_CLI_ARGS_plan \
  TF_REATTACH_PROVIDERS \
  TF_LOG \
  TF_LOG_PROVIDER \
  TF_PLUGIN_CACHE_DIR \
  TF_IN_AUTOMATION \
  TF_VAR_database_password; do
  if (
    VPS_ROOT="$terraform_context_root"
    export "$unsafe_variable=injected"
    guard_vps_terraform_cli_context
  ) >/dev/null 2>&1; then
    fail "Terraform environment injection '$unsafe_variable' passed the production context guard."
  fi
done
for empty_variable in TF_WORKSPACE TF_CLI_CONFIG_FILE; do
  if (
    VPS_ROOT="$terraform_context_root"
    export "$empty_variable="
    guard_vps_terraform_cli_context
  ) >/dev/null 2>&1; then
    fail "Exported empty Terraform setting '$empty_variable' passed the production context guard."
  fi
done

printf '%s\n' staging > "$terraform_context_root/.terraform/environment"
if (
  VPS_ROOT="$terraform_context_root"
  guard_vps_terraform_cli_context
) >/dev/null 2>&1; then
  fail 'A stale non-default .terraform/environment selection passed the production context guard.'
fi
printf '%s\n' default > "$terraform_context_root/.terraform/environment"
(
  VPS_ROOT="$terraform_context_root"
  guard_vps_terraform_cli_context
) || fail 'An explicit cached default workspace was rejected.'

(
  VPS_ROOT="$terraform_context_root"
  terraform() {
    [ "$*" = "-chdir=$VPS_ROOT workspace show" ] || return 1
    printf '%s\n' default
  }
  verify_vps_default_workspace
) || fail 'The exact default VPS workspace was rejected after initialization.'
if (
  VPS_ROOT="$terraform_context_root"
  terraform() { printf '%s\n' staging; }
  verify_vps_default_workspace
) >/dev/null 2>&1; then
  fail 'A non-default VPS workspace was accepted after initialization.'
fi
rm -rf -- "$terraform_context_root"

run_backend_preflight() {
  local scenario="$1"
  (
    BACKEND_BUCKET=apollo-state-test
    BACKEND_REGION=af-south-1
    BACKEND_EXPECTED_ACCOUNT_ID=123456789012
    require_command() { :; }
    aws() {
      case "$*" in
        'sts get-caller-identity --output json')
          if [ "$scenario" = account ]; then
            printf '%s\n' '{"Account":"999999999999","Arn":"arn:aws:iam::999999999999:user/test"}'
          else
            printf '%s\n' '{"Account":"123456789012","Arn":"arn:aws:iam::123456789012:user/test"}'
          fi
          ;;
        s3api*)
          case " $* " in
            *' --bucket apollo-state-test '*) ;;
            *) return 1 ;;
          esac
          case " $* " in
            *' --expected-bucket-owner 123456789012 '*) ;;
            *) return 1 ;;
          esac
          case " $* " in
            *' --region af-south-1 '*) ;;
            *) return 1 ;;
          esac
          case " $* " in
            *' --output json '*) ;;
            *) return 1 ;;
          esac
          case "$*" in
            's3api get-bucket-location '*)
              if [ "$scenario" = region ]; then
                printf '%s\n' '{"LocationConstraint":"eu-west-1"}'
              else
                printf '%s\n' '{"LocationConstraint":"af-south-1"}'
              fi
              ;;
            's3api get-bucket-versioning '*)
              if [ "$scenario" = versioning ]; then
                printf '%s\n' '{"Status":"Suspended"}'
              else
                printf '%s\n' '{"Status":"Enabled"}'
              fi
              ;;
            's3api get-bucket-encryption '*)
              if [ "$scenario" = encryption ]; then
                printf '%s\n' '{"ServerSideEncryptionConfiguration":{"Rules":[]}}'
              else
                printf '%s\n' '{"ServerSideEncryptionConfiguration":{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"aws:kms"}}]}}'
              fi
              ;;
            's3api get-public-access-block '*)
              if [ "$scenario" = public ]; then
                printf '%s\n' '{"PublicAccessBlockConfiguration":{"BlockPublicAcls":true,"IgnorePublicAcls":true,"BlockPublicPolicy":true,"RestrictPublicBuckets":false}}'
              else
                printf '%s\n' '{"PublicAccessBlockConfiguration":{"BlockPublicAcls":true,"IgnorePublicAcls":true,"BlockPublicPolicy":true,"RestrictPublicBuckets":true}}'
              fi
              ;;
            *) return 1 ;;
          esac
          ;;
        *) return 1 ;;
      esac
    }
    verify_backend_safety
  )
}

run_backend_preflight success \
  || fail 'A fully protected account-bound state bucket failed preflight.'
for backend_failure in account region versioning encryption public; do
  if run_backend_preflight "$backend_failure" >/dev/null 2>&1; then
    fail "Unsafe backend scenario '$backend_failure' passed preflight."
  fi
done

(
  TARGET=vps
  provenance_checked=false
  guard_current_vps_release_provenance() {
    provenance_checked=true
  }
  assert_vps_lease_alive() { :; }
  terraform() {
    [ "$*" = "-chdir=$VPS_ROOT output -json reconcile" ] || return 1
    printf '%s\n' '{"transport":"ssh"}'
  }
  bash() {
    [ "$provenance_checked" = true ]
    [ "${APOLLO_RECONCILE_INTERNAL:-}" = setup-v1 ]
    [ "$1" = "$RECONCILE" ]
    [ "$2" = vps ]
    [ "$3" = --phase ]
    [ "$4" = expand ]
    [ "$5" = --roles ]
    [ "$6" = reconcile ]
    [ "$7" = --migrations-only ]
  }
  run_migrations >/dev/null
  [ "$provenance_checked" = true ]
) || fail 'Standalone VPS migration did not verify deployed provenance before refusing contract-phase execution.'

(
  provenance_guard_dir="$(mktemp -d "${TMPDIR:-/tmp}/apollo-current-release-guard.XXXXXX")"
  trap 'rm -rf -- "$provenance_guard_dir"' EXIT
  expected_release='{"platform":{"image":"ghcr.io/apollo-deploy/apollo-platform-api@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","source_commit":"1111111111111111111111111111111111111111"},"signal":{"image":"ghcr.io/apollo-deploy/apollo-signal-api@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","source_commit":"2222222222222222222222222222222222222222"},"billing":{"image":"ghcr.io/apollo-deploy/apollo-billing-api@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc","source_commit":"3333333333333333333333333333333333333333"}}'
  approved_checked=false
  verify_approved_release_manifest() {
    [ "$1" = "$expected_release" ]
    approved_checked=true
  }
  terraform() {
    case "$*" in
      "-chdir=$VPS_ROOT output -json release_manifest")
        printf '%s\n' "$expected_release"
        ;;
      *) return 1 ;;
    esac
  }
  ssh() {
    case " $* " in
      *' -o StrictHostKeyChecking=yes '*) ;;
      *) return 1 ;;
    esac
    case " $* " in
      *' platform apollo-platform ghcr.io/apollo-deploy/apollo-platform-api@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa '*) ;;
      *) return 1 ;;
    esac
    case " $* " in
      *' signal apollo-signal ghcr.io/apollo-deploy/apollo-signal-api@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb '*) ;;
      *) return 1 ;;
    esac
    case " $* " in
      *' billing apollo-billing ghcr.io/apollo-deploy/apollo-billing-api@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc '*) ;;
      *) return 1 ;;
    esac
    live_verifier_source="$(cat)"
    case "$live_verifier_source" in
      *'docker container inspect'*'docker image inspect'*) ;;
      *) return 1 ;;
    esac
  }

  guard_current_vps_release_provenance >/dev/null
  [ "$approved_checked" = true ]
) || fail 'Standalone VPS migration did not require the state-recorded release to be CI-approved before checking live image identity.'

# Brownfield adoption checkpoints the provenance- and live-verified raw
# all-old release. A retry after service 1 changes may therefore accept an
# independently mixed old/desired set instead of recomputing every service as
# already desired from refreshed Terraform state.
(
  old_release='{"platform":{"image":"ghcr.io/apollo-deploy/apollo-platform-api@sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd","source_commit":"4444444444444444444444444444444444444444"},"signal":{"image":"ghcr.io/apollo-deploy/apollo-signal-api@sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee","source_commit":"5555555555555555555555555555555555555555"},"billing":{"image":"ghcr.io/apollo-deploy/apollo-billing-api@sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff","source_commit":"6666666666666666666666666666666666666666"}}'
  desired_release='{"platform":{"image":"ghcr.io/apollo-deploy/apollo-platform-api@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","source_commit":"1111111111111111111111111111111111111111"},"signal":{"image":"ghcr.io/apollo-deploy/apollo-signal-api@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","source_commit":"2222222222222222222222222222222222222222"},"billing":{"image":"ghcr.io/apollo-deploy/apollo-billing-api@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc","source_commit":"3333333333333333333333333333333333333333"}}'
  VPS_STATE_LIST='module.deployment.module.platform.docker_container.platform'
  VPS_REMOTE_IDENTITY_PRESENT=false
  VPS_LAST_COMPLETE_RELEASE_MANIFEST=""
  VPS_VERIFIED_CURRENT_RELEASE_MANIFEST=""
  adoption_provenance_checked=false
  load_remote_deployment_identity() { VPS_REMOTE_IDENTITY_PRESENT=false; }
  confirm() { return 0; }
  guard_current_vps_release_provenance() {
    adoption_provenance_checked=true
    VPS_VERIFIED_CURRENT_RELEASE_MANIFEST="$old_release"
  }
  write_remote_deployment_identity() {
    [ "$adoption_provenance_checked" = true ]
    [ "$1" = "$old_release" ]
    VPS_LAST_COMPLETE_RELEASE_MANIFEST="$1"
    VPS_REMOTE_IDENTITY_PRESENT=true
  }
  ensure_remote_deployment_identity_before_mutation
  [ "$VPS_LAST_COMPLETE_RELEASE_MANIFEST" = "$old_release" ]

  ensure_vps_live_check_connection() { :; }
  transition_plan="$(mktemp "${TMPDIR:-/tmp}/apollo-transition-plan.XXXXXX")"
  trap 'rm -f -- "$transition_plan"' EXIT
  terraform() {
    printf '%s\n' '{"resource_changes":[]}'
  }
  ssh() {
    case " $* " in
      *' platform apollo-platform ghcr.io/apollo-deploy/apollo-platform-api@sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd ghcr.io/apollo-deploy/apollo-platform-api@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa '*) ;;
      *) return 1 ;;
    esac
    case " $* " in
      *' signal apollo-signal ghcr.io/apollo-deploy/apollo-signal-api@sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee ghcr.io/apollo-deploy/apollo-signal-api@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb '*) ;;
      *) return 1 ;;
    esac
    case " $* " in
      *' billing apollo-billing ghcr.io/apollo-deploy/apollo-billing-api@sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff ghcr.io/apollo-deploy/apollo-billing-api@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc '*) ;;
      *) return 1 ;;
    esac
  }
  verify_live_vps_release_transition "$VPS_LAST_COMPLETE_RELEASE_MANIFEST" "$desired_release" "$transition_plan"
) || fail 'Brownfield adoption did not preserve the verified all-old checkpoint for a mixed-service retry.'

run_missing_container_transition() {
  local planned_changes="$1" expected_platform_permission="$2" ssh_result="$3"
  (
    old_release='{"platform":{"image":"ghcr.io/apollo-deploy/apollo-platform-api@sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"},"signal":{"image":"ghcr.io/apollo-deploy/apollo-signal-api@sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"},"billing":{"image":"ghcr.io/apollo-deploy/apollo-billing-api@sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"}}'
    desired_release='{"platform":{"image":"ghcr.io/apollo-deploy/apollo-platform-api@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},"signal":{"image":"ghcr.io/apollo-deploy/apollo-signal-api@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"},"billing":{"image":"ghcr.io/apollo-deploy/apollo-billing-api@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"}}'
    plan_file="$(mktemp "${TMPDIR:-/tmp}/apollo-missing-container-plan.XXXXXX")"
    trap 'rm -f -- "$plan_file"' EXIT
    ensure_vps_live_check_connection() { :; }
    terraform() { printf '{"resource_changes":%s}\n' "$planned_changes"; }
    ssh() {
      case " $* " in
        *" platform apollo-platform ghcr.io/apollo-deploy/apollo-platform-api@sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd ghcr.io/apollo-deploy/apollo-platform-api@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa $expected_platform_permission "*) ;;
        *) return 88 ;;
      esac
      case " $* " in
        *' signal apollo-signal '*' false billing apollo-billing '*' false '*) ;;
        *) return 89 ;;
      esac
      case "$*" in
        *'is missing without an exact saved-plan create action'*) ;;
        *) return 90 ;;
      esac
      return "$ssh_result"
    }
    verify_live_vps_release_transition "$old_release" "$desired_release" "$plan_file"
  )
}

missing_create_changes='[{"address":"module.deployment.module.platform.docker_container.platform","type":"docker_container","change":{"actions":["create"],"after":{"name":"apollo-platform"}}}]'
run_missing_container_transition "$missing_create_changes" true 0 \
  || fail 'A missing canonical app container with an exact saved-plan create was not retryable.'
missing_without_create_output="$(run_missing_container_transition '[]' false 1 2>&1)" \
  && fail 'A missing app container without a saved-plan create passed transition verification.'
assert_contains 'not a resumable mixture' "$missing_without_create_output"

run_marker_identity_check() {
  local marker_volumes="$1" live_volumes="$2" state_json="$3"
  (
    VPS_DEPLOYMENT_ID=0123456789abcdef0123456789abcdef
    VPS_STATE_LINEAGE_ACTUAL=11111111-1111-1111-1111-111111111111
    VPS_TARGET_FINGERPRINT=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
    VPS_STATE_JSON="$state_json"
    run_remote_deployment_marker() {
      printf '{"schema":"apollo-deployment-identity/v1","deployment_id":"%s","state_lineage":"%s","target_sha256":"%s","volumes":%s,"last_complete_release":null}\n' \
        "$VPS_DEPLOYMENT_ID" "$VPS_STATE_LINEAGE_ACTUAL" "$VPS_TARGET_FINGERPRINT" "$marker_volumes"
    }
    read_remote_apollo_volume_identities() { printf '%b' "$live_volumes"; }
    success() { :; }
    load_remote_deployment_identity
  )
}

checkpoint_volumes='{"apollo-postgres-data":"created-old"}'
additive_state='{"values":{"root_module":{"resources":[{"address":"module.deployment.docker_volume.postgres_data[0]","type":"docker_volume","values":{"name":"apollo-postgres-data"}},{"address":"module.deployment.module.postgres_backup[0].docker_volume.backups","type":"docker_volume","values":{"name":"apollo-postgres-backups"}}]}}}'
run_marker_identity_check "$checkpoint_volumes" 'apollo-postgres-data\tcreated-old\napollo-postgres-backups\tcreated-new\n' "$additive_state" \
  || fail 'A post-apply retry rejected an additive volume uniquely owned by canonical state.'
unowned_additive_output="$(run_marker_identity_check "$checkpoint_volumes" 'apollo-postgres-data\tcreated-old\napollo-unowned\tcreated-new\n' "$additive_state" 2>&1)" \
  && fail 'An additional live volume without canonical state ownership passed the checkpoint.'
assert_contains 'does not match state, target, or durable-volume creation identities' "$unowned_additive_output"
replaced_checkpoint_output="$(run_marker_identity_check "$checkpoint_volumes" 'apollo-postgres-data\treplaced\n' "$additive_state" 2>&1)" \
  && fail 'A replaced checkpointed volume passed identity verification.'
assert_contains 'does not match state, target, or durable-volume creation identities' "$replaced_checkpoint_output"

(
  VPS_STATE_LIST='module.network.docker_network.apollo
module.infra.docker_volume.postgres_data'
  VPS_STATE_JSON='{"values":{"root_module":{"resources":[{"address":"module.network.docker_network.apollo","type":"docker_network","values":{"name":"apollo","id":"network-id"}},{"address":"module.infra.docker_volume.postgres_data","type":"docker_volume","values":{"name":"apollo-postgres-data","id":"apollo-postgres-data"}}]}}}'
  VPS_CONFIG_COMMIT_REQUIRED=false
  read_vps_state_list() { :; }
  ssh() {
    printf 'network\tapollo\tnetwork-id\t2026-01-01T00:00:00Z\nvolume\tapollo-postgres-data\tapollo-postgres-data\t2026-01-01T00:00:00Z\n'
  }
  guard_vps_state_against_brownfield_docker
  [ "${#VPS_TRACKED_DURABLE_ADDRESSES[@]}" -eq 1 ]
) || fail 'An exact moved legacy Docker binding was rejected.'

(
  VPS_STATE_LIST='module.deployment.module.network.docker_network.apollo
module.deployment.docker_volume.postgres_data[0]'
  VPS_STATE_JSON='{"values":{"root_module":{"resources":[{"address":"module.deployment.module.network.docker_network.apollo","type":"docker_network","values":{"name":"apollo","id":"network-id"}},{"address":"module.deployment.docker_volume.postgres_data[0]","type":"docker_volume","values":{"name":"apollo-postgres-data","id":"apollo-postgres-data"}}]}}}'
  VPS_CONFIG_COMMIT_REQUIRED=false
  read_vps_state_list() { :; }
  ssh() {
    printf 'network\tapollo\tnetwork-id\t2026-01-01T00:00:00Z\nvolume\tapollo-postgres-data\tapollo-postgres-data\t2026-01-01T00:00:00Z\n'
  }
  guard_vps_state_against_brownfield_docker
  [ "${#VPS_TRACKED_DURABLE_ADDRESSES[@]}" -eq 1 ]
) || fail 'An exact canonical Docker binding was rejected.'

unknown_legacy_output="$({
  (
    VPS_STATE_LIST='module.bootstrap.terraform_data.wait_postgres'
    VPS_CONFIG_COMMIT_REQUIRED=false
    read_vps_state_list() { :; }
    ssh() { fail 'SSH inventory must not run for an unknown legacy address.'; }
    guard_vps_state_against_brownfield_docker
  )
} 2>&1)" && fail 'An unknown legacy address passed the ownership gate.'
assert_contains 'without an approved move' "$unknown_legacy_output"

missing_volume_output="$({
  (
    VPS_STATE_LIST='module.deployment.module.postgres_backup[0].docker_volume.backups'
    VPS_STATE_JSON='{"values":{"root_module":{"resources":[{"address":"module.deployment.module.postgres_backup[0].docker_volume.backups","type":"docker_volume","values":{"name":"apollo-postgres-backups","id":"apollo-postgres-backups"}}]}}}'
    VPS_CONFIG_COMMIT_REQUIRED=false
    read_vps_state_list() { :; }
    ssh() { :; }
    guard_vps_state_against_brownfield_docker
  )
} 2>&1)" && fail 'A missing state-tracked backup volume passed the ownership gate.'
assert_contains 'state-tracked durable volume is missing' "$missing_volume_output"

run_plan_guard() {
  local actions_json="$1"
  (
    VPS_TRACKED_DURABLE_ADDRESSES=(
      'module.deployment.module.postgres_backup[0].docker_volume.backups'
    )
    terraform() {
      printf '{"resource_changes":[{"address":"module.deployment.module.postgres_backup[0].docker_volume.backups","change":{"actions":%s}}]}\n' \
        "$actions_json"
    }
    guard_vps_durable_plan /unused/fake-plan
  )
}

run_plan_guard '["no-op"]' \
  || fail 'A no-op tracked durable-volume plan was rejected.'
create_plan_output="$(run_plan_guard '["create"]' 2>&1)" \
  && fail 'A create action for a tracked durable volume passed the saved-plan gate.'
assert_contains 'create, replace, or delete' "$create_plan_output"
replacement_plan_output="$(run_plan_guard '["delete","create"]' 2>&1)" \
  && fail 'A replacement action for a tracked durable volume passed the saved-plan gate.'
assert_contains 'create, replace, or delete' "$replacement_plan_output"
delete_plan_output="$(run_plan_guard '["delete"]' 2>&1)" \
  && fail 'A delete action for a tracked durable volume passed the saved-plan gate.'
assert_contains 'create, replace, or delete' "$delete_plan_output"
(
  VPS_TRACKED_DURABLE_ADDRESSES=()
  terraform() { fail 'Greenfield plan guard unexpectedly inspected a plan.'; }
  guard_vps_durable_plan /unused/greenfield-plan
) || fail 'A greenfield durable-volume create was rejected.'

run_sns_plan_guard() {
  local actions_json="$1"
  local replacement_allowed="$2"
  (
    VPS_PLAN_GUARD_SNS=true
    SNS_REPLACEMENT_ALLOWED="$replacement_allowed"
    VPS_DOMAIN=example.com
    terraform() {
      printf '{"resource_changes":[{"address":"aws_sns_topic_subscription.signal_ses_events[0]","change":{"actions":%s,"after":{"endpoint":"https://api.signal.example.com/v1/ses-events/ingest","protocol":"https"}}}]}\n' \
        "$actions_json"
    }
    guard_vps_sns_subscription_plan /unused/fake-plan
  )
}

run_sns_plan_guard '["no-op"]' false \
  || fail 'An unchanged SNS subscription was rejected by the first-stage guard.'
sns_replacement_output="$(run_sns_plan_guard '["delete","create"]' false 2>&1)" \
  && fail 'An SNS endpoint replacement passed before TLS staging.'
assert_contains 'before its new TLS endpoint is ready' "$sns_replacement_output"
run_sns_plan_guard '["delete","create"]' true \
  || fail 'A post-TLS SNS endpoint replacement was rejected.'

(
  release_guard_dir="$(mktemp -d "${TMPDIR:-/tmp}/apollo-release-plan-guard.XXXXXX")"
  trap 'rm -rf -- "$release_guard_dir"' EXIT
  RELEASE_SOURCE_VERIFIER="$release_guard_dir/verifier.sh"
  release_audit="$release_guard_dir/args"
  approved_release_audit="$release_guard_dir/approved-releases.jsonl"
  export release_audit approved_release_audit
  cat > "$RELEASE_SOURCE_VERIFIER" <<'VERIFY'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$release_audit"
VERIFY
  verify_approved_release_manifest() {
    printf '%s\n' "$1" >>"$approved_release_audit"
  }
  VPS_PLAN_GUARD_RELEASE=true
  VPS_CURRENT_RELEASE_MANIFEST='{"platform":{"image":"ghcr.io/apollo-deploy/apollo-platform-api@sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd","source_commit":"4444444444444444444444444444444444444444"},"signal":{"image":"ghcr.io/apollo-deploy/apollo-signal-api@sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee","source_commit":"5555555555555555555555555555555555555555"},"billing":{"image":"ghcr.io/apollo-deploy/apollo-billing-api@sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff","source_commit":"6666666666666666666666666666666666666666"}}'
  REPO_ROOT=/reviewed/repo
  release_plan="$release_guard_dir/release.tfplan"
  : >"$release_plan"
  terraform() {
    printf '%s\n' '{"variables":{"release_manifest":{"value":{"platform":{"image":"ghcr.io/apollo-deploy/apollo-platform-api@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","source_commit":"1111111111111111111111111111111111111111"},"signal":{"image":"ghcr.io/apollo-deploy/apollo-signal-api@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","source_commit":"2222222222222222222222222222222222222222"},"billing":{"image":"ghcr.io/apollo-deploy/apollo-billing-api@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc","source_commit":"3333333333333333333333333333333333333333"}}}},"resource_changes":[]}'
  }
  ssh() {
    case " $* " in
      *' -o StrictHostKeyChecking=yes '*) ;;
      *) return 1 ;;
    esac
    case " $* " in
      *' platform apollo-platform ghcr.io/apollo-deploy/apollo-platform-api@sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd '*) ;;
      *) return 1 ;;
    esac
    case " $* " in
      *' ghcr.io/apollo-deploy/apollo-platform-api@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa '*) ;;
      *) return 1 ;;
    esac
    case " $* " in
      *' signal apollo-signal ghcr.io/apollo-deploy/apollo-signal-api@sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee '*) ;;
      *) return 1 ;;
    esac
    case " $* " in
      *' ghcr.io/apollo-deploy/apollo-signal-api@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb '*) ;;
      *) return 1 ;;
    esac
    case " $* " in
      *' billing apollo-billing ghcr.io/apollo-deploy/apollo-billing-api@sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff '*) ;;
      *) return 1 ;;
    esac
    case " $* " in
      *' ghcr.io/apollo-deploy/apollo-billing-api@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc '*) ;;
      *) return 1 ;;
    esac
    cat >/dev/null
  }
  guard_vps_release_sources "$release_plan"
  grep -Fq 'platform /reviewed/repo/apollo-platform-api 1111111111111111111111111111111111111111' "$release_audit"
  grep -Fq 'billing /reviewed/repo/apollo-billing-api 3333333333333333333333333333333333333333' "$release_audit"
  [ "$(wc -l <"$approved_release_audit" | tr -d ' ')" = 2 ]
  grep -Fq 'apollo-platform-api@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' "$approved_release_audit"
  grep -Fq 'apollo-platform-api@sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd' "$approved_release_audit"
) || fail 'The saved-plan guard did not require both desired and prior releases to be CI-approved before live transition checks.'

run_dmarc_preflight() {
  local active_mode="$1"
  (
    VPS_DMARC_ENABLED=true
    SIGNAL_AWS_REGION=af-south-1
    DMARC_IDENTITY=reports.example.com
    DMARC_RECEIPT_RULE_SET=existing-signal-inbound
    aws() {
      case " $* " in
        *' --region af-south-1 '*) ;;
        *) return 1 ;;
      esac
      case "$*" in
        *get-identity-verification-attributes*)
          printf '%s\n' '{"VerificationAttributes":{"reports.example.com":{"VerificationStatus":"Success"}}}'
          ;;
        *describe-active-receipt-rule-set*)
          case "$active_mode" in
            match) printf '%s\n' '{"Metadata":{"Name":"existing-signal-inbound"}}' ;;
            mismatch) printf '%s\n' '{"Metadata":{"Name":"other-active-set"}}' ;;
            missing) printf '%s\n' '{}' ;;
            *) return 1 ;;
          esac
          ;;
        *) return 1 ;;
      esac
    }
    verify_dmarc_receiving_identity
  )
}

run_dmarc_preflight match \
  || fail 'A verified identity with the exact active receipt rule set was rejected.'
dmarc_mismatch_output="$(run_dmarc_preflight mismatch 2>&1)" \
  && fail 'A mismatched active DMARC receipt rule set passed preflight.'
assert_contains 'is not active' "$dmarc_mismatch_output"
dmarc_missing_output="$(run_dmarc_preflight missing 2>&1)" \
  && fail 'A missing active DMARC receipt rule set passed preflight.'
assert_contains '(active: Missing)' "$dmarc_missing_output"

run_backup_check() {
  local scenario="$1"
  (
    VPS_OFFSITE_ENABLED=true
    BACKUP_HEALTH_TIMEOUT_SECONDS=0
    BACKUP_HEALTH_POLL_SECONDS=0
    read_backup_health_status() {
      case "$scenario" in
        healthy) printf '%s\n' healthy ;;
        starting) printf '%s\n' starting ;;
        restarting) printf '%s\n' restarting ;;
        unhealthy) printf '%s\n' unhealthy ;;
        paused) printf '%s\n' paused ;;
        *) return 1 ;;
      esac
    }
    verify_backup_health
  )
}

run_backup_check healthy \
  || fail 'Healthy primary and offsite backup containers were rejected.'
backup_starting_output="$(run_backup_check starting 2>&1)" \
  && fail 'Perpetual starting backup containers passed readiness.'
assert_contains 'timed out' "$backup_starting_output"
backup_restarting_output="$(run_backup_check restarting 2>&1)" \
  && fail 'Perpetually restarting backup containers passed readiness.'
assert_contains 'timed out' "$backup_restarting_output"
backup_unhealthy_output="$(run_backup_check unhealthy 2>&1)" \
  && fail 'Unhealthy backup containers passed readiness.'
assert_contains 'failed backup readiness' "$backup_unhealthy_output"
backup_paused_output="$(run_backup_check paused 2>&1)" \
  && fail 'Paused backup containers passed readiness.'
assert_contains 'failed backup readiness' "$backup_paused_output"
backup_missing_output="$(run_backup_check missing 2>&1)" \
  && fail 'Missing backup containers passed readiness.'
assert_contains 'is missing or could not be inspected' "$backup_missing_output"

run_setup_bootstrap_case() {
  local proxied="$1"
  local plan_only="$2"
  local subscription_mode="$3"
  (
    PLAN_ONLY="$plan_only"
    PLAN_APPLIED=false
    VPS_PROXIED="$proxied"
    bootstrap_calls=0
    plan_calls=0
    init_calls=0
    terraform_context_guard_calls=0
    event_file="$(mktemp "${TMPDIR:-/tmp}/apollo-setup-events.XXXXXX")"
    workspace_check_file="$(mktemp "${TMPDIR:-/tmp}/apollo-workspace-checks.XXXXXX")"
    trap 'rm -f -- "$event_file" "$workspace_check_file"' EXIT

    require_command() { :; }
    require_source_checkout() { :; }
    guard_legacy_root_identity() { :; }
    write_backend_config() { :; }
    verify_backend_safety() { :; }
    guard_vps_terraform_cli_context() {
      terraform_context_guard_calls=$((terraform_context_guard_calls + 1))
    }
    random_hex() { printf '%064d\n' 0; }
    terraform() {
      case "$*" in
        "-chdir=$VPS_ROOT init -reconfigure -input=false -backend-config=backend.hcl -lockfile=readonly -no-color")
          init_calls=$((init_calls + 1))
          ;;
        "-chdir=$VPS_ROOT workspace show")
          printf '%s\n' checked >> "$workspace_check_file"
          printf '%s\n' default
          ;;
        *'state show aws_sns_topic_subscription.signal_ses_events[0]'*)
          [ "$subscription_mode" != missing ]
          ;;
        *'show -json'*)
          endpoint='https://api.signal.example.com/v1/ses-events/ingest'
          [ "$subscription_mode" != changed ] \
            || endpoint='https://api.signal.old.example.com/v1/ses-events/ingest'
          printf '{"values":{"root_module":{"resources":[{"address":"aws_sns_topic_subscription.signal_ses_events[0]","values":{"endpoint":"%s"}}]}}}\n' "$endpoint"
          ;;
        *) return 0 ;;
      esac
    }
    read_vps_state_list() { :; }
    write_vps_config() { :; }
    validate_vps_input_contract() { printf '%s\n' input-validated >> "$event_file"; }
    read_server_config() {
      VPS_PROXIED="$proxied"
      VPS_PORT=2222
      VPS_KEY_EXPANDED=/tmp/apollo-setup-test-key
      VPS_USER=deploy
      VPS_HOST=host.example.com
      VPS_DOMAIN=example.com
      VPS_EMAIL=ops@example.com
      BACKEND_EXPECTED_ACCOUNT_ID=123456789012
      SIGNAL_AWS_ACCOUNT_ID=123456789012
    }
    verify_ssh() { :; }
    guard_vps_deployment_identity_before_ssh() { :; }
    acquire_vps_lease() { :; }
    assert_vps_lease_alive() { :; }
    guard_vps_state_against_brownfield_docker() { :; }
    ensure_remote_deployment_identity_before_mutation() { VPS_REMOTE_IDENTITY_PRESENT=true; }
    refresh_vps_state_lineage_binding() { :; }
    guard_current_vps_release_provenance() { :; }
    write_remote_deployment_identity() { :; }
    commit_vps_config() { :; }
    ensure_cloudflare_token() { :; }
    acknowledge_backup_scope() { :; }
    verify_dmarc_receiving_identity() { :; }
    adopt_cloudflare_records() { :; }
    verify_public_endpoints() { :; }
    verify_certbot_renewal_health() { :; }
    verify_backup_health() { :; }
    run_terraform_plan() {
      plan_calls=$((plan_calls + 1))
      printf 'plan %s\n' "$*" >> "$event_file"
      case " $* " in
        *' --after-plan guard_vps_durable_plan --before-apply run_vps_predeploy_migrations '*|\
        *' --after-plan guard_vps_durable_plan --before-apply verify_deferred_sns_endpoint_before_apply '*) ;;
        *) fail 'A hosted plan was not wired through its saved-plan and immediate pre-apply safety hooks.' ;;
      esac
      if [ "$plan_only" = true ]; then
        PLAN_APPLIED=false
      else
        PLAN_APPLIED=true
      fi
    }
    confirm() { fail 'Hosted setup must not make the mandatory bootstrap optional.'; }
    bash() {
      case "$1" in
        "$BOOTSTRAP")
          bootstrap_calls=$((bootstrap_calls + 1))
          printf '%s\n' bootstrap >> "$event_file"
          case "$proxied:$*" in
            "true:$BOOTSTRAP -p 2222 -i /tmp/apollo-setup-test-key deploy@host.example.com") ;;
            "false:$BOOTSTRAP -d -p 2222 -i /tmp/apollo-setup-test-key deploy@host.example.com") ;;
            *) return 1 ;;
          esac
          ;;
        "$RECONCILE") printf '%s\n' reconcile >> "$event_file" ;;
        "$SETUP_TLS") printf '%s\n' tls >> "$event_file" ;;
        *) return 1 ;;
      esac
    }

    setup_vps
    [ "$terraform_context_guard_calls" -eq 1 ] \
      || fail 'Hosted setup did not guard the Terraform CLI context before initialization.'
    [ "$init_calls" -eq 1 ] \
      || fail 'Hosted setup did not initialize with the reviewed dependency lock file read-only.'
    [ "$(wc -l < "$workspace_check_file" | tr -d ' ')" -eq 1 ] \
      || fail 'Hosted setup did not verify the default workspace after initialization.'
    if [ "$plan_only" = true ]; then
      [ "$bootstrap_calls" -eq 0 ]
      [ "$plan_calls" -eq 1 ]
      if grep -Eq '^(bootstrap|reconcile|tls)$' "$event_file"; then
        fail 'Plan-only setup performed a remote mutation.'
      fi
    else
      [ "$bootstrap_calls" -eq 1 ]
      validation_line="$(grep -n '^input-validated$' "$event_file" | cut -d: -f1)"
      bootstrap_line="$(grep -n '^bootstrap$' "$event_file" | cut -d: -f1)"
      [ -n "$validation_line" ] && [ -n "$bootstrap_line" ] \
        && [ "$validation_line" -lt "$bootstrap_line" ] \
        || fail 'Reused production tfvars were not validated before the first host mutation.'
      [ "$(grep -E '^(bootstrap|plan )' "$event_file" | sed -n '1p')" = bootstrap ] \
        || fail 'Host bootstrap did not precede the first Terraform plan.'
      case "$subscription_mode" in
        same)
          [ "$plan_calls" -eq 1 ]
          if grep -Eq 'enable_ses_feedback_subscription=false|ses_feedback_endpoint_override=' "$event_file"; then
            fail 'An unchanged SNS endpoint was unnecessarily staged.'
          fi
          ;;
        missing)
          [ "$plan_calls" -eq 2 ]
          sed -n '/^plan /{p;q;}' "$event_file" \
            | grep -Fq -- '-var=enable_ses_feedback_subscription=false' \
            || fail 'A new SNS subscription was not deferred until after TLS.'
          ;;
        changed)
          [ "$plan_calls" -eq 2 ]
          sed -n '/^plan /{p;q;}' "$event_file" \
            | grep -Fq -- '-var=ses_feedback_endpoint_override=https://api.signal.old.example.com/v1/ses-events/ingest' \
            || fail 'A replacement SNS subscription did not retain the old endpoint through the first apply.'
          ;;
      esac
      if [ "$subscription_mode" != same ]; then
        tls_line="$(grep -n '^tls$' "$event_file" | cut -d: -f1)"
        second_plan_line="$(grep -n '^plan ' "$event_file" | sed -n '2s/:.*//p')"
        [ -n "$tls_line" ] && [ -n "$second_plan_line" ] \
          && [ "$tls_line" -lt "$second_plan_line" ] \
          || fail 'The deferred SNS plan ran before the desired TLS endpoint was ready.'
      fi
    fi
  )
}

run_setup_bootstrap_case true false same \
  || fail 'A proxied production run did not enforce the mandatory host-policy bootstrap.'
run_setup_bootstrap_case false false same \
  || fail 'A direct production run did not enforce the mandatory host-policy bootstrap.'
if run_setup_bootstrap_case true false changed >/dev/null 2>&1; then
  fail 'A base-domain/SNS endpoint change passed the immutable target workflow.'
fi
run_setup_bootstrap_case true false missing \
  || fail 'A first SNS subscription did not stage creation after TLS.'
run_setup_bootstrap_case true true same \
  || fail 'Plan-only mode mutated the VPS through bootstrap.'

(
  migrate_root="$(mktemp -d "${TMPDIR:-/tmp}/apollo-migrate-context.XXXXXX")"
  trap 'rm -rf -- "$migrate_root"' EXIT
  : > "$migrate_root/terraform.tfvars"
  : > "$migrate_root/backend.hcl"
  TARGET=vps
  VPS_ROOT="$migrate_root"
  PLAN_ONLY=false
  terraform_context_guard_calls=0
  init_calls=0
  workspace_check_file="$migrate_root/workspace-checks"
  : > "$workspace_check_file"

  require_command() { :; }
  require_source_checkout() { :; }
  guard_legacy_root_identity() { :; }
  write_backend_config() { :; }
  verify_backend_safety() { :; }
  guard_vps_terraform_cli_context() {
    terraform_context_guard_calls=$((terraform_context_guard_calls + 1))
  }
  terraform() {
    case "$*" in
      "-chdir=$VPS_ROOT init -reconfigure -input=false -backend-config=backend.hcl -lockfile=readonly -no-color")
        init_calls=$((init_calls + 1))
        ;;
      "-chdir=$VPS_ROOT workspace show")
        printf '%s\n' checked >> "$workspace_check_file"
        printf '%s\n' default
        ;;
      *) return 1 ;;
    esac
  }
  begin_existing_vps_transaction() { :; }
  confirm() { return 1; }

  migrate_services >/dev/null
  [ "$terraform_context_guard_calls" -eq 1 ]
  [ "$init_calls" -eq 1 ]
  [ "$(wc -l < "$workspace_check_file" | tr -d ' ')" -eq 1 ]
) || fail 'Standalone VPS migration did not guard context and verify the default workspace around initialization.'

(
  VPS_STATE_LIST='module.infra.docker_container.postgres'
  terraform() {
    case "$*" in
      *'state show module.deployment.module.infra.docker_container.postgres'*) return 1 ;;
      *'state show module.infra.docker_container.postgres'*) return 0 ;;
      *'output -json reconcile'*)
        printf '%s\n' '{
          "database": {
            "user":"postgres",
            "password":"database-secret",
            "name":"apollo_deploy_platform",
            "signal_name":"apollo_deploy_signal",
            "roles":{"platform_app":"platform-secret","billing_app":"billing-secret","billing_superuser":"billing-super-secret","signal_app":"signal-secret","signal_superuser":"signal-super-secret","platform_verifier":"verifier-secret"}
          }
        }'
        ;;
      *'show -json'*)
        printf '%s\n' '{
          "variables": {
            "server": {"value":{"host":"203.0.113.10","user":"deploy","ssh_port":22,"ssh_key_path":"/tmp/test-key"}},
            "release_manifest": {"value":{"platform":{"source_commit":"1111111111111111111111111111111111111111"},"signal":{"source_commit":"2222222222222222222222222222222222222222"},"billing":{"source_commit":"3333333333333333333333333333333333333333"}}},
            "database": {"value":{"user":"postgres","name":"apollo_deploy_platform","password":"database-secret","platform_app_password":"platform-secret","billing_app_password":"billing-secret","billing_superuser_password":"billing-super-secret","signal_app_password":"signal-secret","signal_superuser_password":"signal-super-secret","platform_verifier_password":"verifier-secret"}}
          },
          "prior_state":{"values":{"root_module":{"resources":[]}}},
          "planned_values":{"root_module":{"resources":[]}},
          "resource_changes":[]
        }'
        ;;
      *) return 1 ;;
    esac
  }
  bash() {
    [ "${APOLLO_RECONCILE_INTERNAL:-}" = setup-v1 ] || return 1
    [ "${APOLLO_RECONCILE_JSON+x}" != x ] || return 1
    [ "$*" = "$RECONCILE vps --phase expand --roles skip --migrations-only" ] || return 1
    reconcile_payload="$(cat)"
    printf '%s' "$reconcile_payload" | jq -e '
      .vps.host == "203.0.113.10" and
      .release.platform.source_commit == "1111111111111111111111111111111111111111" and
      .database.password == "database-secret" and
      .database.roles.platform_verifier == "verifier-secret"
    ' >/dev/null
  }
  assert_vps_lease_alive() { :; }
  PLAN_FILE="$SETUP_SCRIPT"
  run_vps_predeploy_migrations
) || fail 'Pre-deploy migrations did not accept the legacy PostgreSQL address or exact saved-plan inputs.'

run_database_identity_guard_case() {
  local changed_identity_field="$1"
  local guard_path="${2:-direct}"
  local current_user=current_admin
  local current_password='CURRENT-ROOT-PASSWORD-DO-NOT-PRINT'
  local current_name=current_platform
  local current_signal_name=apollo_deploy_signal
  local planned_user="$current_user"
  local planned_password="$current_password"
  local planned_name="$current_name"

  case "$changed_identity_field" in
    user) planned_user=rotated_admin ;;
    password) planned_password='PLANNED-ROOT-PASSWORD-DO-NOT-PRINT' ;;
    name) planned_name=rotated_platform ;;
    signal_name) current_signal_name=historical_signal ;;
    *) return 2 ;;
  esac

  (
    PLAN_FILE="$SETUP_SCRIPT"
    VPS_STATE_LIST='module.deployment.docker_volume.postgres_data[0]'
    VPS_TRACKED_DURABLE_ADDRESSES=()
    VPS_PLAN_GUARD_RELEASE=false
    VPS_PLAN_GUARD_SNS=false
    terraform() {
      case "$*" in
        *'output -json reconcile'*)
          printf '{"database":{"user":"%s","password":"%s","name":"%s","signal_name":"%s","roles":{"platform_app":"platform-role","billing_app":"billing-role","billing_superuser":"billing-super-role","signal_app":"signal-role","signal_superuser":"signal-super-role","platform_verifier":"verifier-role"}}}\n' \
            "$current_user" "$current_password" "$current_name" "$current_signal_name"
          ;;
        *'show -json'*)
          printf '{"variables":{"database":{"value":{"user":"%s","password":"%s","name":"%s","platform_app_password":"platform-role","billing_app_password":"billing-role","billing_superuser_password":"billing-super-role","signal_app_password":"signal-role","signal_superuser_password":"signal-super-role","platform_verifier_password":"verifier-role"}}}}\n' \
            "$planned_user" "$planned_password" "$planned_name"
          ;;
        *) return 1 ;;
      esac
    }
    if [ "$guard_path" = after-plan ]; then
      guard_vps_durable_plan "$PLAN_FILE"
    else
      guard_vps_database_identity_plan "$PLAN_FILE"
    fi
  )
}

for changed_identity_field in user password name signal_name; do
  identity_guard_output="$(run_database_identity_guard_case "$changed_identity_field" 2>&1)" \
    && fail "An init-only PostgreSQL $changed_identity_field change passed the brownfield saved-plan guard."
  assert_contains 'PostgreSQL root/scoped credential or init-only database identity' "$identity_guard_output"
  case "$identity_guard_output" in
    *'CURRENT-ROOT-PASSWORD-DO-NOT-PRINT'*|*'PLANNED-ROOT-PASSWORD-DO-NOT-PRINT'*)
      fail 'The PostgreSQL identity guard leaked a compared password.'
      ;;
  esac
done

plan_only_identity_output="$(run_database_identity_guard_case password after-plan 2>&1)" \
  && fail 'A plan-only preview accepted a PostgreSQL root-password rotation.'
assert_contains 'PostgreSQL root/scoped credential or init-only database identity' "$plan_only_identity_output"

run_scoped_credential_rotation_guard() {
  (
    VPS_STATE_LIST='module.deployment.module.infra.docker_container.postgres'
    terraform() {
      case "$*" in
        *'output -json reconcile'*)
          printf '%s\n' '{"database":{"user":"postgres","password":"root-secret","name":"apollo_deploy_platform","signal_name":"apollo_deploy_signal","roles":{"platform_app":"old-platform","billing_app":"old-billing","billing_superuser":"old-billing-super","signal_app":"old-signal","signal_superuser":"old-signal-super","platform_verifier":"old-verifier"}}}'
          ;;
        *'show -json'*)
          printf '%s\n' '{"variables":{"database":{"value":{"user":"postgres","password":"root-secret","name":"apollo_deploy_platform","platform_app_password":"new-platform","billing_app_password":"old-billing","billing_superuser_password":"old-billing-super","signal_app_password":"old-signal","signal_superuser_password":"old-signal-super","platform_verifier_password":"old-verifier"}}}}'
          ;;
        *) return 1 ;;
      esac
    }
    guard_vps_database_identity_plan "$SETUP_SCRIPT"
  )
}

scoped_rotation_output="$(run_scoped_credential_rotation_guard 2>&1)" \
  && fail 'An ordinary brownfield scoped-role password rotation was accepted.'
assert_contains 'cannot safely split credentials across a partial apply' "$scoped_rotation_output"

run_runtime_credential_rotation_guard() {
  local scenario="$1"
  (
    VPS_STATE_LIST='module.deployment.module.infra.docker_container.postgres'
    terraform() {
      case "$*" in
        *'output -json reconcile'*)
          printf '%s\n' '{"database":{"user":"postgres","password":"root-secret","name":"apollo_deploy_platform","signal_name":"apollo_deploy_signal","roles":{"platform_app":"platform-role","billing_app":"billing-role","billing_superuser":"billing-super-role","signal_app":"signal-role","signal_superuser":"signal-super-role","platform_verifier":"verifier-role"}}}'
          ;;
        *'show -json'*)
          if [ "$scenario" = shared-secret ]; then
            printf '%s\n' '{
              "variables":{"database":{"value":{"user":"postgres","password":"root-secret","name":"apollo_deploy_platform","platform_app_password":"platform-role","billing_app_password":"billing-role","billing_superuser_password":"billing-super-role","signal_app_password":"signal-role","signal_superuser_password":"signal-super-role","platform_verifier_password":"verifier-role"}}},
              "prior_state":{"values":{"root_module":{"resources":[{"address":"module.deployment.module.platform.docker_container.platform","type":"docker_container","values":{"name":"apollo-platform","env":["SESSION_SECRET=previous-secret"]}}]}}},
              "planned_values":{"root_module":{"resources":[{"address":"module.deployment.module.platform.docker_container.platform","type":"docker_container","values":{"name":"apollo-platform","env":["SESSION_SECRET=desired-secret"]}}]}},
              "resource_changes":[]
            }'
          else
            printf '%s\n' '{
              "variables":{"database":{"value":{"user":"postgres","password":"root-secret","name":"apollo_deploy_platform","platform_app_password":"platform-role","billing_app_password":"billing-role","billing_superuser_password":"billing-super-role","signal_app_password":"signal-role","signal_superuser_password":"signal-super-role","platform_verifier_password":"verifier-role"}}},
              "prior_state":{"values":{"root_module":{"resources":[]}}},
              "planned_values":{"root_module":{"resources":[]}},
              "resource_changes":[{"address":"module.deployment.module.oauth.random_uuid.client_id","type":"random_uuid","change":{"before":{"result":"old-id"},"after":{"result":"new-id"},"actions":["delete","create"]}}]
            }'
          fi
          ;;
        *) return 1 ;;
      esac
    }
    guard_vps_database_identity_plan "$SETUP_SCRIPT"
  )
}

shared_rotation_output="$(run_runtime_credential_rotation_guard shared-secret 2>&1)" \
  && fail 'An ordinary shared-secret replacement that can split the runtime was accepted.'
assert_contains 'rotates runtime, shared, or OAuth credentials' "$shared_rotation_output"
oauth_rotation_output="$(run_runtime_credential_rotation_guard oauth-identity 2>&1)" \
  && fail 'An ordinary OAuth identity replacement that can split the runtime was accepted.'
assert_contains 'rotates runtime, shared, or OAuth credentials' "$oauth_rotation_output"

(
  reconciliation_events="$(mktemp "${TMPDIR:-/tmp}/apollo-reconciliation-order.XXXXXX")"
  trap 'rm -f -- "$reconciliation_events"' EXIT
  assert_vps_lease_alive() { :; }
  terraform() {
    [ "$*" = "-chdir=$VPS_ROOT output -json reconcile" ] || return 1
    printf '%s\n' '{"transport":"ssh"}'
  }
  bash() {
    printf '%s|%s\n' "${APOLLO_RECONCILE_INTERNAL:-missing}" "$*" >> "$reconciliation_events"
    cat >/dev/null
  }

  run_vps_postapply_reconciliation
  [ "$(cat "$reconciliation_events")" = "setup-v1|$RECONCILE vps --phase expand --roles reconcile" ]
) || fail 'Normal post-apply reconciliation was not restricted to the expand phase.'

# The native backend boundary and canonical key are both mandatory; the comment
# annotation alone is not an account guard.
for backend_tamper in wrong-key wrong-native-account; do
  (
    fixture="$(mktemp "${TMPDIR:-/tmp}/apollo-backend-tamper.XXXXXX")"
    trap 'rm -f -- "$fixture"' EXIT
    cat >"$fixture" <<'BACKEND'
# apollo_expected_account_id = "123456789012"
# apollo_deployment_id = "0123456789abcdef0123456789abcdef"
# apollo_state_lineage = "unbound"
# apollo_target_sha256 = "unbound"
bucket = "apollo-state-test"
key = "apollo/vps/terraform.tfstate"
region = "af-south-1"
encrypt = true
use_lockfile = true
allowed_account_ids = ["123456789012"]
BACKEND
    case "$backend_tamper" in
      wrong-key) sed -i.bak 's#apollo/vps/terraform.tfstate#apollo/vps/other.tfstate#' "$fixture" ;;
      wrong-native-account) sed -i.bak 's/allowed_account_ids = \["123456789012"\]/allowed_account_ids = ["999999999999"]/' "$fixture" ;;
    esac
    rm -f -- "$fixture.bak"
    read_backend_config "$fixture"
  ) >/dev/null 2>&1 && fail "Backend tamper '$backend_tamper' passed the canonical identity boundary."
done

# An implicit ~/.terraformrc dev_override cannot influence hosted provider
# installation because the wizard always supplies its own mode-0600 config.
(
  context_home="$(mktemp -d "${TMPDIR:-/tmp}/apollo-cli-home.XXXXXX")"
  trap 'rm -rf -- "$context_home"; [ -z "${VPS_TF_CLI_CONFIG_FILE:-}" ] || rm -f -- "$VPS_TF_CLI_CONFIG_FILE"' EXIT
  printf '%s\n' 'provider_installation { dev_overrides { "hashicorp/aws" = "/tmp/evil" } direct {} }' >"$context_home/.terraformrc"
  HOME="$context_home"
  VPS_ROOT="$context_home/root"
  mkdir -p "$VPS_ROOT/.terraform"
  printf '%s\n' default >"$VPS_ROOT/.terraform/environment"
  VPS_TF_CLI_CONFIG_FILE=""
  unset TF_CLI_CONFIG_FILE
  prepare_vps_terraform_cli_context
  [ "$TF_CLI_CONFIG_FILE" = "$VPS_TF_CLI_CONFIG_FILE" ]
  [ "$TF_CLI_CONFIG_FILE" != "$context_home/.terraformrc" ]
  [ "$(stat -c '%a' "$TF_CLI_CONFIG_FILE" 2>/dev/null || stat -f '%Lp' "$TF_CLI_CONFIG_FILE")" = 600 ]
  grep -Fq 'disable_checkpoint = true' "$TF_CLI_CONFIG_FILE"
  if grep -Fq dev_overrides "$TF_CLI_CONFIG_FILE"; then
    fail 'Wizard-owned Terraform CLI configuration inherited a provider dev_override.'
  fi
) || fail 'Implicit Terraform CLI provider overrides were not neutralized.'

# Exact state target values are immutable in the ordinary workflow and are
# checked before any SSH call could occur.
run_target_mismatch() {
  (
    BACKEND_EXPECTED_ACCOUNT_ID=123456789012
    BACKEND_BUCKET=apollo-state-test
    VPS_HOST=new-host.example.com
    VPS_USER=deploy
    VPS_PORT=22
    VPS_DOMAIN=example.com
    VPS_TARGET_FINGERPRINT=unbound
    VPS_STATE_LINEAGE=11111111-1111-1111-1111-111111111111
    VPS_STATE_LINEAGE_ACTUAL=11111111-1111-1111-1111-111111111111
    VPS_STATE_LIST='module.deployment.module.network.docker_network.apollo'
    terraform() {
      case "$*" in
        *'output -json reconcile') printf '%s\n' '{"vps":{"host":"old-host.example.com","user":"deploy","ssh_port":22}}' ;;
        *'output -json public_urls') printf '%s\n' '{"platform_api":"https://api.platform.example.com"}' ;;
        *) return 1 ;;
      esac
    }
    ssh() { fail 'Target mismatch reached SSH.'; }
    guard_vps_deployment_identity_before_ssh
  )
}
target_mismatch_output="$(run_target_mismatch 2>&1)" \
  && fail 'A state-bound VPS host change passed normal setup.'
assert_contains 'differs from canonical state' "$target_mismatch_output"

# State-derived ownership rejects unknown namespace objects, unexpected network
# members, and same-name containers with a different immutable Docker ID.
run_inventory_rejection() {
  local scenario="$1"
  (
    VPS_STATE_LIST='module.deployment.module.network.docker_network.apollo
module.deployment.module.platform.docker_container.platform'
    VPS_STATE_JSON='{"values":{"root_module":{"resources":[{"address":"module.deployment.module.network.docker_network.apollo","type":"docker_network","values":{"name":"apollo","id":"network-id"}},{"address":"module.deployment.module.platform.docker_container.platform","type":"docker_container","values":{"name":"apollo-platform","id":"container-id"}}]}}}'
    VPS_CONFIG_COMMIT_REQUIRED=false
    read_vps_state_list() { :; }
    ssh() {
      case "$scenario" in
        unknown) printf 'network\tapollo\tnetwork-id\tcreated\ncontainer\tapollo-platform\tcontainer-id\tcreated\ncontainer\tapollo-old-writer\told-id\tcreated\n' ;;
        member) printf 'network\tapollo\tnetwork-id\tcreated\ncontainer\tapollo-platform\tcontainer-id\tcreated\nmember\tunmanaged-writer\t-\t-\n' ;;
        recreated) printf 'network\tapollo\tnetwork-id\tcreated\ncontainer\tapollo-platform\trecreated-id\tcreated\n' ;;
      esac
    }
    guard_vps_state_against_brownfield_docker
  )
}
for inventory_scenario in unknown member recreated; do
  run_inventory_rejection "$inventory_scenario" >/dev/null 2>&1 \
    && fail "Unsafe Docker inventory '$inventory_scenario' passed ownership verification."
done

# The deployment marker command itself rejects a writable/untrusted parent and
# refuses to follow a pre-positioned marker symlink before reading or writing.
(
  marker_root="$(mktemp -d "${TMPDIR:-/tmp}/apollo-marker-storage.XXXXXX")"
  trap 'rm -f -- "$marker_root/marker" "$marker_root/target"; rmdir "$marker_root" 2>/dev/null || true' EXIT
  chmod 700 "$marker_root"
  marker_command="$(vps_deployment_marker_remote_command)"
  if /bin/bash -c "$marker_command" apollo-marker read "$marker_root/missing/marker" self >/dev/null 2>&1; then
    fail 'A missing greenfield deployment-marker parent was reported as present.'
  else
    [ "$?" -eq 44 ] || fail 'A missing greenfield deployment-marker parent did not use the absent-marker status.'
  fi
  printf '%s\n' original >"$marker_root/marker"
  chmod 600 "$marker_root/marker"
  [ "$(/bin/bash -c "$marker_command" apollo-marker read "$marker_root/marker" self)" = original ]
  printf '%s\n' replacement \
    | /bin/bash -c "$marker_command" apollo-marker write "$marker_root/marker" self
  [ "$(cat "$marker_root/marker")" = replacement ]

  chmod 777 "$marker_root"
  if /bin/bash -c "$marker_command" apollo-marker read "$marker_root/marker" self >/dev/null 2>&1; then
    fail 'A world-writable deployment marker parent passed the storage boundary.'
  fi
  chmod 700 "$marker_root"
  rm -f -- "$marker_root/marker"
  printf '%s\n' untouched >"$marker_root/target"
  ln -s "$marker_root/target" "$marker_root/marker"
  if printf '%s\n' forged \
    | /bin/bash -c "$marker_command" apollo-marker write "$marker_root/marker" self >/dev/null 2>&1; then
    fail 'A pre-positioned deployment marker symlink was followed or replaced.'
  fi
  [ "$(cat "$marker_root/target")" = untouched ]
  rm -f -- "$marker_root/marker"
  printf '%s\n' original >"$marker_root/marker"
  chmod 600 "$marker_root/marker"
  if /bin/bash -c "$marker_command" apollo-marker read "$marker_root/marker" 999999 >/dev/null 2>&1; then
    fail 'A deployment marker parent with an owner outside the trusted identity passed.'
  fi
) || fail 'Deployment marker storage ownership, mode, symlink, or atomic-write guard failed.'

# Root-held lease storage is checked before flock opens anything. These fakes
# model a local user pre-positioning a symlink, a writable parent, or an object
# owned outside the trusted identity.
run_lease_storage_rejection() {
  local scenario="$1"
  (
    lease_parent="$(mktemp -d "${TMPDIR:-/tmp}/apollo-lease-storage.XXXXXX")"
    trap 'rm -f -- "$lease_parent/apollo-deploy/vps.lock" 2>/dev/null || true; rm -f -- "$lease_parent/apollo-deploy" 2>/dev/null || true; rmdir "$lease_parent/apollo-deploy" 2>/dev/null || true; rmdir "$lease_parent" 2>/dev/null || true' EXIT
    chmod 700 "$lease_parent"
    trusted_uid="$(id -u)"
    case "$scenario" in
      symlink) ln -s /tmp "$lease_parent/apollo-deploy" ;;
      file-symlink)
        mkdir -m 700 "$lease_parent/apollo-deploy"
        ln -s /tmp/forged-lease-target "$lease_parent/apollo-deploy/vps.lock"
        ;;
      writable) chmod 777 "$lease_parent" ;;
      owner) trusted_uid=999999 ;;
      *) return 2 ;;
    esac
    lease_command="$(vps_lease_remote_command)"
    /bin/bash -c "$lease_command" apollo-lease \
      0123456789abcdef0123456789abcdef 0 "$lease_parent" "$trusted_uid" </dev/null
  )
}
for lease_storage_scenario in symlink file-symlink writable owner; do
  run_lease_storage_rejection "$lease_storage_scenario" >/dev/null 2>&1 \
    && fail "Unsafe lease storage '$lease_storage_scenario' reached flock."
done

# A post-TLS SNS stage may not smuggle an unrelated mutation into its second
# saved plan.
if (
  VPS_PLAN_GUARD_SNS=true
  SNS_REPLACEMENT_ALLOWED=true
  VPS_DOMAIN=example.com
  terraform() {
    printf '%s\n' '{"resource_changes":[{"address":"aws_sns_topic_subscription.signal_ses_events[0]","change":{"actions":["create"],"after":{"endpoint":"https://api.signal.example.com/v1/ses-events/ingest","protocol":"https"}}},{"address":"aws_s3_bucket.unrelated","change":{"actions":["update"],"after":{}}}]}'
  }
  guard_vps_sns_subscription_plan /unused/plan
) >/dev/null 2>&1; then
  fail 'An unrelated mutation passed the exact second-stage SNS plan guard.'
fi

# The lease fake holds one atomic remote directory until the first session
# releases it; a concurrent wizard fails without reaching a mutation.
run_lease_concurrency_fake() {
(
  lease_root="$(mktemp -d "${TMPDIR:-/tmp}/apollo-lease-fake.XXXXXX")"
  trap 'release_vps_lease; rmdir "$lease_root/held" 2>/dev/null || true; rmdir "$lease_root" 2>/dev/null || true' EXIT
  VPS_DEPLOYMENT_ID=0123456789abcdef0123456789abcdef
  VPS_USER=deploy
  VPS_HOST=host.example.com
  VPS_SSH_ARGS=(-o StrictHostKeyChecking=yes)
  VPS_LEASE_TEMP_DIR=""
  VPS_LEASE_PID=""
  VPS_LEASE_FIFO=""
  VPS_LEASE_STATUS_FILE=""
  VPS_LEASE_FD_OPEN=false
  ssh() {
    if ! mkdir "$lease_root/held" 2>/dev/null; then
      printf '%s\n' 'ERROR: another Apollo deployment transaction holds the VPS lease.'
      return 75
    fi
    printf '%s\n' ACQUIRED
    while IFS= read -r command; do
      if [ "$command" = release ]; then
        rmdir "$lease_root/held"
        return 0
      fi
      rmdir "$lease_root/held" 2>/dev/null || true
      return 2
    done
    rmdir "$lease_root/held" 2>/dev/null || true
    return 2
  }
  acquire_vps_lease >/dev/null
  if (
    VPS_LEASE_TEMP_DIR=""
    VPS_LEASE_PID=""
    VPS_LEASE_FIFO=""
    VPS_LEASE_STATUS_FILE=""
    VPS_LEASE_FD_OPEN=false
    acquire_vps_lease
  ) >/dev/null 2>&1; then
    fail 'A concurrent fake wizard acquired the already-held deployment lease.'
  fi
  assert_vps_lease_alive
  release_vps_lease
  [ ! -e "$lease_root/held" ]
)
}
lease_fake_output="$(run_lease_concurrency_fake 2>&1)" \
  || fail "Deployment-wide lease acquisition, exclusion, liveness, or release failed: $lease_fake_output"

# Direct VPS reconciliation has neither a state-output fallback nor an implicit
# phase; public hosted operations must route through setup.sh.
direct_reconcile_output="$(bash "$RECONCILE" vps --phase expand --roles skip --migrations-only </dev/null 2>&1)" \
  && fail 'Direct VPS reconciliation bypassed the setup orchestration boundary.'
assert_contains 'internal to infra/setup.sh' "$direct_reconcile_output"
forbidden_all_output="$(printf '%s' '{}' \
  | APOLLO_RECONCILE_INTERNAL=setup-v1 bash "$RECONCILE" vps --phase all --roles reconcile 2>&1)" \
  && fail 'A combined VPS expand/contract reconciliation was accepted.'
assert_contains 'never combines expand and contract' "$forbidden_all_output"
forbidden_contract_output="$(printf '%s' '{}' \
  | APOLLO_RECONCILE_INTERNAL=setup-v1 bash "$RECONCILE" vps --phase contract --roles skip --migrations-only 2>&1)" \
  && fail 'A locally forgeable VPS contract-migration execution path remained.'
assert_contains 'separately governed DBA/release process' "$forbidden_contract_output"
setup_contract_output="$(bash "$SETUP_SCRIPT" contract vps --evidence /tmp/forged.json 2>&1)" \
  && fail 'The setup wizard still accepted a locally authored contract approval.'
assert_contains 'Unknown option: contract' "$setup_contract_output"

# The configured registry namespace is not operator-selectable, and deployment
# no longer requires a local Cosign installation.
if grep -Fq 'GHCR registry path' "$SETUP_SCRIPT"; then
  fail 'Production setup still prompts for an arbitrary registry namespace.'
fi
if grep -Eq 'require_command[[:space:]]+cosign|require_cosign_v3' "$SETUP_SCRIPT"; then
  fail 'Production setup still requires a local Cosign installation.'
fi

echo 'VPS setup safety regression tests passed.'
