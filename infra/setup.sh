#!/usr/bin/env bash

# Interactive infrastructure operations for Apollo Deploy. Local helpers remain
# directly usable by CI; hosted helpers are private primitives of this wizard.
set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LOCAL_ROOT="$SCRIPT_DIR/terraform/local"
VPS_ROOT="$SCRIPT_DIR/terraform/vps"
AWS_BOOTSTRAP_ROOT="$SCRIPT_DIR/terraform/bootstrap"
AWS_BOOTSTRAP_BACKEND="$AWS_BOOTSTRAP_ROOT/backend.hcl"
AWS_BOOTSTRAP_BACKEND_BLOCK="$AWS_BOOTSTRAP_ROOT/backend.generated.tf"
BOOTSTRAP="$SCRIPT_DIR/scripts/bootstrap-vps.sh"
RECONCILE="$SCRIPT_DIR/scripts/reconcile-services.sh"
SETUP_TLS="$SCRIPT_DIR/scripts/setup-vps-tls.sh"
RELEASE_SOURCE_VERIFIER="$SCRIPT_DIR/scripts/lib/verify-release-sources.sh"
APPROVED_RELEASE_VERIFIER="$SCRIPT_DIR/scripts/lib/verify-approved-release.sh"
APPROVED_RELEASES_FILE="$SCRIPT_DIR/releases/approved-releases.json"
LIVE_RELEASE_IMAGE_VERIFIER="$SCRIPT_DIR/scripts/lib/verify-live-release-images.sh"
CANONICAL_VPS_STATE_KEY="apollo/vps/terraform.tfstate"
LOCAL_TLS_DIR="$REPO_ROOT/apollo-platform-api/scripts/nginx/certs"
LOCAL_TLS_CERT="$LOCAL_TLS_DIR/apollo-local.pem"
LOCAL_TLS_KEY="$LOCAL_TLS_DIR/apollo-local-key.pem"
LOCAL_TLS_ROOT_CA=""
LEGACY_ROOTS_DIR="$SCRIPT_DIR/terraform/environments"

ACTION=""
TARGET=""
PLAN_ONLY=false
USE_COLOR=true
ANSWER=""
PLAN_FILE=""
WRITE_FILE=false
PLAN_APPLIED=false
SNS_SUBSCRIPTION_DEFERRED=false
SNS_CURRENT_ENDPOINT=""
SNS_REPLACEMENT_ALLOWED=false
VPS_PLAN_GUARD_SNS=false
VPS_PLAN_GUARD_RELEASE=false
VPS_CURRENT_RELEASE_MANIFEST=""
VPS_VERIFIED_CURRENT_RELEASE_MANIFEST=""
VPS_STATE_LIST=""
VPS_STATE_JSON=""
VPS_STATE_LINEAGE=""
VPS_DEPLOYMENT_ID=""
VPS_TARGET_FINGERPRINT=""
VPS_LAST_COMPLETE_RELEASE_MANIFEST=""
VPS_REMOTE_IDENTITY_PRESENT=false
VPS_VAR_FILE="$VPS_ROOT/terraform.tfvars"
VPS_CONFIG_CANDIDATE=""
VPS_CONFIG_COMMIT_REQUIRED=false
VPS_PROXIED=""
VPS_OFFSITE_ENABLED=""
VPS_DMARC_ENABLED=""
SIGNAL_AWS_REGION=""
SIGNAL_AWS_REGIONS_JSON="[]"
DMARC_IDENTITY=""
DMARC_RECEIPT_RULE_SET=""
BACKUP_HEALTH_TIMEOUT_SECONDS="${APOLLO_BACKUP_HEALTH_TIMEOUT_SECONDS:-1800}"
BACKUP_HEALTH_POLL_SECONDS="${APOLLO_BACKUP_HEALTH_POLL_SECONDS:-15}"
NON_INTERACTIVE=false
CUSTOM_LOCAL_CONFIG="${APOLLO_LOCAL_CONFIG_FILE:-}"
CUSTOM_VPS_CONFIG="${APOLLO_VPS_CONFIG_FILE:-}"
CUSTOM_BACKEND_CONFIG="${APOLLO_BACKEND_CONFIG_FILE:-}"
STATE_BUCKET_OPTION="${APOLLO_STATE_BUCKET_NAME:-}"
OPERATOR_TOPIC_OPTION="${APOLLO_OPERATOR_TOPIC_NAME:-apollo-production-operator-alerts}"
CLOUDFLARE_TOKEN_FILE="${APOLLO_CLOUDFLARE_TOKEN_FILE:-}"
SIGNAL_REGIONS_OPTION="${APOLLO_SIGNAL_REGIONS:-}"
SIGNAL_PRIMARY_REGION_OPTION="${APOLLO_SIGNAL_PRIMARY_REGION:-}"
RELEASE_ID_OPTION="${APOLLO_RELEASE_ID:-}"
APPROVED_RELEASE_JSON=""
AWS_BOOTSTRAP_PLANNED=false
BOOTSTRAP_AWS_ACCOUNT_ID=""
BOOTSTRAP_OPERATOR_ALERT_TOPIC_ARN=""
VPS_TRACKED_DURABLE_ADDRESSES=()
VPS_SSH_ARGS=(-o StrictHostKeyChecking=yes)
VPS_LEASE_TEMP_DIR=""
VPS_LEASE_FIFO=""
VPS_LEASE_STATUS_FILE=""
VPS_LEASE_PID=""
VPS_LEASE_FD_OPEN=false
VPS_TF_CLI_CONFIG_FILE=""
BACKEND_BUCKET=""
BACKEND_REGION=""
BACKEND_EXPECTED_ACCOUNT_ID=""
SIGNAL_AWS_ACCOUNT_ID=""
LOCAL_DEV_MODE=""
LOCAL_SIGNAL_ENABLED=""
CHANGED_SERVICES=()

usage() {
  cat <<'USAGE'
Usage:
  bash infra/setup.sh [local|vps] [options]
  bash infra/setup.sh migrate [local|vps] [--no-color]
  bash infra/setup.sh update [local] [options]

  local        Configure and start the local Docker environment
  vps          Configure and deploy the hosted VPS environment
  migrate      Run pending database migrations without restarting APIs
  update       Refresh only APIs with local worktree changes (local only)
  --plan-only  Stop after producing a Terraform plan
  --no-color   Disable ANSI colors
  --non-interactive
               Require explicit action/target and existing or supplied config;
               only plan-only operations are allowed
  --local-config FILE
               Install a complete protected local terraform.tfvars file
  --vps-config FILE
               Stage a complete protected VPS terraform.tfvars file
  --backend-config FILE
               Install a complete protected VPS backend.hcl file
  --state-bucket NAME
               Override the generated globally unique S3 state bucket name
  --operator-topic NAME
               Override the generated operator-alert SNS topic name
  --cloudflare-token-file FILE
               Read the Cloudflare API token from a protected file
  --signal-regions REGIONS
               Comma-separated Signal AWS regions, or "all"
  --signal-primary-region REGION
               Primary region for Signal's durable AWS infrastructure
  --release ID
               Select a CI-approved immutable production release
  --backup-health-timeout SECONDS
               Maximum wait for the first current PostgreSQL backup
  --backup-health-poll SECONDS
               Polling interval while waiting for backup health

  File and timeout options may also be supplied with APOLLO_LOCAL_CONFIG_FILE,
  APOLLO_VPS_CONFIG_FILE, APOLLO_BACKEND_CONFIG_FILE,
  APOLLO_STATE_BUCKET_NAME, APOLLO_OPERATOR_TOPIC_NAME,
  APOLLO_CLOUDFLARE_TOKEN_FILE, APOLLO_SIGNAL_PRIMARY_REGION,
  APOLLO_SIGNAL_REGIONS, APOLLO_RELEASE_ID,
  APOLLO_BACKUP_HEALTH_TIMEOUT_SECONDS, and APOLLO_BACKUP_HEALTH_POLL_SECONDS.
  Explicit CLI options take precedence.
USAGE
}

while (($# > 0)); do
  case "$1" in
    setup|--setup)
      [ -z "$ACTION" ] || { echo "Choose only one action." >&2; exit 2; }
      ACTION="setup"
      ;;
    migrate|--migrate)
      [ -z "$ACTION" ] || { echo "Choose only one action." >&2; exit 2; }
      ACTION="migrate"
      ;;
    update|--update)
      [ -z "$ACTION" ] || { echo "Choose only one action." >&2; exit 2; }
      ACTION="update"
      ;;
    local|--local)
      [ -z "$TARGET" ] || { echo "Choose only one environment." >&2; exit 2; }
      TARGET="local"
      ;;
    vps|--vps)
      [ -z "$TARGET" ] || { echo "Choose only one environment." >&2; exit 2; }
      TARGET="vps"
      ;;
    --plan-only) PLAN_ONLY=true ;;
    --no-color) USE_COLOR=false ;;
    --non-interactive) NON_INTERACTIVE=true ;;
    --local-config|--vps-config|--backend-config|--state-bucket|--operator-topic|--cloudflare-token-file|--signal-primary-region|--signal-regions|--release|--backup-health-timeout|--backup-health-poll)
      [ "$#" -ge 2 ] || { echo "$1 requires a value." >&2; exit 2; }
      case "$1" in
        --local-config) CUSTOM_LOCAL_CONFIG="$2" ;;
        --vps-config) CUSTOM_VPS_CONFIG="$2" ;;
        --backend-config) CUSTOM_BACKEND_CONFIG="$2" ;;
        --state-bucket) STATE_BUCKET_OPTION="$2" ;;
        --operator-topic) OPERATOR_TOPIC_OPTION="$2" ;;
        --cloudflare-token-file) CLOUDFLARE_TOKEN_FILE="$2" ;;
        --signal-regions) SIGNAL_REGIONS_OPTION="$2" ;;
        --signal-primary-region) SIGNAL_PRIMARY_REGION_OPTION="$2" ;;
        --release) RELEASE_ID_OPTION="$2" ;;
        --backup-health-timeout) BACKUP_HEALTH_TIMEOUT_SECONDS="$2" ;;
        --backup-health-poll) BACKUP_HEALTH_POLL_SECONDS="$2" ;;
      esac
      shift
      ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

[[ "$BACKUP_HEALTH_TIMEOUT_SECONDS" =~ ^[0-9]+$ ]] \
  && [[ "$BACKUP_HEALTH_POLL_SECONDS" =~ ^[0-9]+$ ]] \
  || { echo "Backup health timeout and poll values must be positive integers." >&2; exit 2; }
((10#$BACKUP_HEALTH_TIMEOUT_SECONDS > 0 && 10#$BACKUP_HEALTH_POLL_SECONDS > 0)) \
  || { echo "Backup health timeout and poll values must be positive integers." >&2; exit 2; }
((10#$BACKUP_HEALTH_POLL_SECONDS <= 10#$BACKUP_HEALTH_TIMEOUT_SECONDS)) \
  || { echo "Backup health polling cannot exceed the timeout." >&2; exit 2; }

if $NON_INTERACTIVE && ! $PLAN_ONLY; then
  echo "Non-interactive mode is restricted to --plan-only; production apply requires review and interactive approval." >&2
  exit 2
fi

if [ ! -t 1 ] || [ -n "${NO_COLOR:-}" ] || [ "${TERM:-}" = "dumb" ]; then
  USE_COLOR=false
fi

if $USE_COLOR; then
  ESC="$(printf '\033')"
  BOLD="${ESC}[1m"
  DIM="${ESC}[2m"
  BLUE="${ESC}[34m"
  GREEN="${ESC}[32m"
  YELLOW="${ESC}[33m"
  RED="${ESC}[31m"
  RESET="${ESC}[0m"
else
  BOLD="" DIM="" BLUE="" GREEN="" YELLOW="" RED="" RESET=""
fi

cleanup() {
  release_vps_lease
  if [ -n "$PLAN_FILE" ] && [ -f "$PLAN_FILE" ]; then
    rm -f -- "$PLAN_FILE"
  fi
  if [ -n "$VPS_CONFIG_CANDIDATE" ] && [ -f "$VPS_CONFIG_CANDIDATE" ]; then
    rm -f -- "$VPS_CONFIG_CANDIDATE"
  fi
  if [ -n "$VPS_TF_CLI_CONFIG_FILE" ] && [ -f "$VPS_TF_CLI_CONFIG_FILE" ]; then
    rm -f -- "$VPS_TF_CLI_CONFIG_FILE"
  fi
  unset TF_CLI_CONFIG_FILE
}
trap cleanup EXIT

banner() {
  printf '\n%sApollo Deploy%s\n' "$BOLD" "$RESET"
  printf '%sLean infrastructure operations%s\n\n' "$DIM" "$RESET"
}

section() {
  printf '\n%s%s%s\n' "$BOLD$BLUE" "$1" "$RESET"
}

info() {
  printf '%s•%s %s\n' "$BLUE" "$RESET" "$1"
}

success() {
  printf '%s✓%s %s\n' "$GREEN" "$RESET" "$1"
}

warn() {
  printf '%s!%s %s\n' "$YELLOW" "$RESET" "$1" >&2
}

die() {
  printf '%sError:%s %s\n' "$RED" "$RESET" "$1" >&2
  exit 1
}

require_tty() {
  [ -t 0 ] || die "Interactive setup requires a terminal. Use the underlying Terraform roots in CI."
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "Required command is unavailable: $1"
}

portable_file_owner() {
  stat -f '%u' "$1" 2>/dev/null || stat -c '%u' "$1" 2>/dev/null
}

portable_file_mode() {
  stat -f '%Lp' "$1" 2>/dev/null || stat -c '%a' "$1" 2>/dev/null
}

protected_input_file() {
  local requested_path="$1"
  local label="$2"
  local resolved_path owner mode

  resolved_path="$(expand_home "$requested_path")"
  [ -f "$resolved_path" ] && [ ! -L "$resolved_path" ] && [ -r "$resolved_path" ] \
    || die "$label must be a readable regular file and not a symbolic link: $resolved_path"
  owner="$(portable_file_owner "$resolved_path")" \
    || die "Could not verify the owner of $label: $resolved_path"
  [ "$owner" = "$(id -u)" ] \
    || die "$label must be owned by the current user: $resolved_path"
  mode="$(portable_file_mode "$resolved_path")" \
    || die "Could not verify the mode of $label: $resolved_path"
  case "$mode" in
    400|600) ;;
    *) die "$label must have mode 0400 or 0600: $resolved_path" ;;
  esac
  printf '%s\n' "$resolved_path"
}

install_protected_config() {
  local requested_path="$1"
  local target="$2"
  local label="$3"
  local source_path tmp

  source_path="$(protected_input_file "$requested_path" "$label")"
  if [ -e "$target" ] && [ "$source_path" -ef "$target" ]; then
    chmod 600 "$target"
    info "Using $target"
    return 0
  fi
  [ ! -f "$target" ] || backup_file "$target"
  tmp="$(mktemp "$(dirname "$target")/.apollo-config.XXXXXX")"
  chmod 600 "$tmp"
  cp "$source_path" "$tmp"
  chmod 600 "$tmp"
  mv "$tmp" "$target"
  success "Installed $label at $target"
}

read_protected_secret() {
  local source_path
  source_path="$(protected_input_file "$1" "$2")"
  ANSWER="$(tr -d '\r\n' <"$source_path")"
  [ -n "$ANSWER" ] || die "$2 is empty: $source_path"
}

require_source_checkout() {
  local required_dir
  local required_dirs=(
    "$REPO_ROOT/apollo-platform-api"
    "$REPO_ROOT/apollo-platform-api/scripts/nginx"
    "$REPO_ROOT/apollo-platform-api/scripts/nginx/conf.d"
    "$REPO_ROOT/apollo-platform-api/scripts/nginx/snippets"
    "$REPO_ROOT/apollo-platform-api/scripts/nginx/local"
    "$REPO_ROOT/apollo-platform-api/scripts/migrations"
    "$REPO_ROOT/apollo-billing-api"
    "$REPO_ROOT/apollo-billing-api/scripts/migrations"
    "$REPO_ROOT/apollo-signal-api"
    "$REPO_ROOT/apollo-signal-api/scripts/migrations"
  )

  for required_dir in "${required_dirs[@]}"; do
    [ -d "$required_dir" ] || die "Required service source is missing: $required_dir. Initialize the repository submodules before continuing."
  done
}

verify_approved_release_manifest() {
  local release_json="$1"
  local manifest_path="infra/releases/approved-releases.json"

  [ -f "$APPROVED_RELEASES_FILE" ] && [ ! -L "$APPROVED_RELEASES_FILE" ] \
    || die "The CI-approved release manifest is unavailable."
  git -C "$REPO_ROOT" ls-files --error-unmatch -- "$manifest_path" >/dev/null 2>&1 \
    || die "The approved release manifest must be committed before production use."
  if ! git -C "$REPO_ROOT" diff --quiet -- "$manifest_path" \
    || ! git -C "$REPO_ROOT" diff --cached --quiet -- "$manifest_path"; then
    die "The approved release manifest has uncommitted changes; CI approval applies only to the committed file."
  fi

  printf '%s' "$release_json" | /bin/bash "$APPROVED_RELEASE_VERIFIER" "$APPROVED_RELEASES_FILE" \
    || die "The release is not an exact CI-approved image/commit combination."
}

select_approved_release() {
  local release_id="$RELEASE_ID_OPTION"
  local default_release

  default_release="$(jq -er '
    select(.schema_version == 1)
    | .releases
    | select(type == "array" and length > 0)
    | .[-1].id
  ' "$APPROVED_RELEASES_FILE" 2>/dev/null)" \
    || die "No CI-approved production release is available. Publish and review one before deployment."

  if [ -z "$release_id" ]; then
    jq -r '.releases[] | "  \(.id)  \(.approved_at)"' "$APPROVED_RELEASES_FILE"
    prompt "Approved release" "$default_release"
    release_id="$ANSWER"
  fi
  [[ "$release_id" =~ ^[a-z0-9][a-z0-9._-]{0,63}$ ]] \
    || die "The approved release ID is invalid."
  APPROVED_RELEASE_JSON="$(jq -ce --arg id "$release_id" '
    [.releases[] | select(.id == $id)]
    | if length == 1 then .[0].services else error("release selection") end
  ' "$APPROVED_RELEASES_FILE")" \
    || die "Release $release_id is not present exactly once in the approved manifest."
  verify_approved_release_manifest "$APPROVED_RELEASE_JSON"
  success "Selected CI-approved release $release_id."
}

guard_legacy_root_identity() {
  local target="$1"
  local legacy_root="$LEGACY_ROOTS_DIR/$target"
  local artifact

  [ -d "$legacy_root" ] || return 0
  for artifact in \
    "$legacy_root/main.tf" \
    "$legacy_root/variables.tf" \
    "$legacy_root/outputs.tf" \
    "$legacy_root/terraform.tfvars" \
    "$legacy_root/terraform.tfvars.json" \
    "$legacy_root"/*.auto.tfvars \
    "$legacy_root"/*.auto.tfvars.json \
    "$legacy_root"/terraform.tfstate \
    "$legacy_root"/terraform.tfstate.* \
    "$legacy_root"/terraform.tfstate.backup; do
    [ -e "$artifact" ] || continue
    die "Legacy $target Terraform state or configuration exists under $legacy_root. Refusing to initialize a second state identity; migrate or remove the legacy state before continuing."
  done
}

prompt() {
  local label="$1"
  local default_value="${2:-}"
  $NON_INTERACTIVE && die "Missing required non-interactive input: $label"
  if [ -n "$default_value" ]; then
    printf '%s%s%s %s[%s]%s: ' "$BOLD" "$label" "$RESET" "$DIM" "$default_value" "$RESET"
  else
    printf '%s%s%s: ' "$BOLD" "$label" "$RESET"
  fi
  IFS= read -r ANSWER || die "Input ended unexpectedly."
  if [ -z "$ANSWER" ]; then
    ANSWER="$default_value"
  fi
}

prompt_secret() {
  local label="$1"
  $NON_INTERACTIVE && die "Missing required non-interactive secret: $label"
  while :; do
    printf '%s%s%s: ' "$BOLD" "$label" "$RESET"
    IFS= read -r -s ANSWER || die "Input ended unexpectedly."
    printf '\n'
    [ -n "$ANSWER" ] && return
    warn "A value is required."
  done
}

confirm() {
  local label="$1"
  local default_value="${2:-yes}"
  local suffix="[Y/n]"
  $NON_INTERACTIVE && die "Non-interactive input cannot answer confirmation: $label"
  [ "$default_value" = "no" ] && suffix="[y/N]"

  while :; do
    printf '%s%s%s %s%s%s: ' "$BOLD" "$label" "$RESET" "$DIM" "$suffix" "$RESET"
    IFS= read -r ANSWER || die "Input ended unexpectedly."
    [ -n "$ANSWER" ] || ANSWER="$default_value"
    case "$ANSWER" in
      y|Y|yes|YES|Yes) return 0 ;;
      n|N|no|NO|No) return 1 ;;
      *) warn "Enter yes or no." ;;
    esac
  done
}

prompt_valid() {
  local label="$1"
  local default_value="$2"
  local validator="$3"
  local error_message="$4"
  while :; do
    prompt "$label" "$default_value"
    "$validator" "$ANSWER" && return
    warn "$error_message"
  done
}

valid_nonempty() { [ -n "$1" ]; }
valid_port() { [[ "$1" =~ ^[0-9]+$ ]] && ((10#$1 >= 1 && 10#$1 <= 65535)); }
valid_zone_id() { [[ "$1" =~ ^[0-9a-fA-F]{32}$ ]]; }
valid_domain() { [[ "$1" =~ ^([A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]]; }
valid_email() { [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._%+-]*@[A-Za-z0-9][A-Za-z0-9.-]*\.[A-Za-z]{2,63}$ ]]; }
valid_host() { [[ "$1" =~ ^([A-Za-z0-9][A-Za-z0-9.-]*|\[[0-9A-Fa-f:]+\])$ ]]; }
valid_user() { [[ "$1" =~ ^[a-z_][a-z0-9_-]*$ ]]; }
valid_region() { [[ "$1" =~ ^[a-z]{2}(-[a-z]+)+-[0-9]+$ ]]; }
valid_signal_region() {
  case "$1" in
    af-south-1|ap-southeast-1|eu-west-1|us-east-1) return 0 ;;
    *) return 1 ;;
  esac
}

normalize_signal_regions() {
  local requested="$1"
  local primary_region="$2"
  local region supported candidate supported_region
  local selected=()
  local candidates=()
  local supported_regions=(af-south-1 ap-southeast-1 eu-west-1 us-east-1)

  [ -n "$requested" ] || requested="$primary_region"
  [ "$requested" != all ] || requested="af-south-1,ap-southeast-1,eu-west-1,us-east-1"

  IFS=',' read -r -a candidates <<EOF
$requested
EOF
  for candidate in "${candidates[@]}"; do
    region="${candidate//[[:space:]]/}"
    [ -n "$region" ] || return 1
    supported=false
    for supported_region in "${supported_regions[@]}"; do
      if [ "$supported_region" = "$region" ]; then
        supported=true
        break
      fi
    done
    $supported || return 1
  done

  requested="$(printf '%s' "$requested" | tr -d '[:space:]')"
  for candidate in "${supported_regions[@]}"; do
    if [ "$candidate" = "$primary_region" ] || [[ ",$requested," == *",$candidate,"* ]]; then
      selected+=("$candidate")
    fi
  done
  [ "${#selected[@]}" -gt 0 ] || return 1
  SIGNAL_AWS_REGIONS_JSON="$(printf '%s\n' "${selected[@]}" | jq -Rsc 'split("\n") | map(select(length > 0))')"
}
valid_aws_account_id() { [[ "$1" =~ ^[0-9]{12}$ ]]; }
valid_sns_topic_arn() { [[ "$1" =~ ^arn:[a-z0-9-]+:sns:[a-z0-9-]+:[0-9]{12}:[A-Za-z0-9_-]{1,256}$ ]]; }
valid_bucket() { [[ "$1" =~ ^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$ ]]; }
valid_image_digest() { [[ "$1" =~ ^sha256:[0-9a-f]{64}$ ]]; }
valid_git_commit() { [[ "$1" =~ ^[0-9a-f]{40}$ ]]; }

valid_ipv4() {
  local ip="$1"
  local a b c d octet
  IFS=. read -r a b c d <<EOF
$ip
EOF
  [ -n "${a:-}" ] && [ -n "${b:-}" ] && [ -n "${c:-}" ] && [ -n "${d:-}" ] || return 1
  for octet in "$a" "$b" "$c" "$d"; do
    [[ "$octet" =~ ^[0-9]{1,3}$ ]] || return 1
    ((10#$octet <= 255)) || return 1
  done

  # A public DNS origin must be globally routable unicast. Keep this list in
  # sync with the native Terraform validations in vps/variables.tf and the
  # Cloudflare DNS module.
  case "$a.$b.$c.$d" in
    0.*|10.*|127.*|169.254.*|192.0.0.*|192.0.2.*|192.168.*|198.51.100.*|203.0.113.*) return 1 ;;
  esac
  ((10#$a == 100 && 10#$b >= 64 && 10#$b <= 127)) && return 1
  ((10#$a == 172 && 10#$b >= 16 && 10#$b <= 31)) && return 1
  ((10#$a == 198 && (10#$b == 18 || 10#$b == 19))) && return 1
  ((10#$a >= 224)) && return 1
  return 0
}

expand_home() {
  case "$1" in
    \~/*) printf '%s/%s\n' "$HOME" "${1#\~/}" ;;
    *) printf '%s\n' "$1" ;;
  esac
}

backup_file() {
  local source_file="$1"
  local backup_dir
  backup_dir="$(dirname "$source_file")/.setup-backups"
  mkdir -p "$backup_dir"
  chmod 700 "$backup_dir"
  cp -p "$source_file" "$backup_dir/$(basename "$source_file").$(date +%Y%m%d-%H%M%S)"
  info "Backed up $(basename "$source_file") under .setup-backups/."
}

prepare_file() {
  local path="$1"
  local label="$2"
  WRITE_FILE=false
  if [ ! -f "$path" ]; then
    WRITE_FILE=true
    return
  fi
  if $NON_INTERACTIVE; then
    chmod 600 "$path"
    info "Reusing $path"
    return
  fi
  if confirm "Reuse existing $label?" yes; then
    chmod 600 "$path"
    info "Reusing $path"
    return
  fi
  backup_file "$path"
  WRITE_FILE=true
}

run_terraform_plan() {
  local root="$1"
  local before_apply=""
  local after_plan=""
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --before-apply)
        [ "$#" -ge 2 ] || die "A before-apply callback is required."
        before_apply="$2"
        shift 2
        ;;
      --after-plan)
        [ "$#" -ge 2 ] || die "An after-plan callback is required."
        after_plan="$2"
        shift 2
        ;;
      *) break ;;
    esac
  done
  PLAN_APPLIED=false
  PLAN_FILE="$(mktemp "${TMPDIR:-/tmp}/apollo-terraform-plan.XXXXXX")"
  chmod 600 "$PLAN_FILE"

  section "Terraform plan"
  terraform -chdir="$root" validate -no-color
  if [ "$root" = "$VPS_ROOT" ] && $VPS_PLAN_GUARD_RELEASE; then
    capture_current_vps_release_manifest
  fi
  terraform -chdir="$root" plan -input=false -no-color -out="$PLAN_FILE" "$@"
  if [ -n "$after_plan" ]; then
    "$after_plan" "$PLAN_FILE"
  fi

  if $PLAN_ONLY; then
    success "Plan completed; Terraform apply was not run."
    return
  fi
  if ! confirm "Apply this exact plan?" no; then
    info "Terraform apply cancelled."
    return
  fi
  if [ -n "$before_apply" ]; then
    "$before_apply"
  fi
  if [ "$root" = "$VPS_ROOT" ]; then
    assert_vps_lease_alive
  fi

  section "Applying"
  terraform -chdir="$root" apply -input=false -no-color "$PLAN_FILE"
  rm -f -- "$PLAN_FILE"
  PLAN_FILE=""
  PLAN_APPLIED=true
}

select_action() {
  [ -z "$ACTION" ] || return 0
  [ -z "$TARGET" ] || { ACTION="setup"; return 0; }
  printf '  %s1%s  Set up an environment\n' "$BOLD" "$RESET"
  printf '  %s2%s  Run database migrations\n' "$BOLD" "$RESET"
  printf '  %s3%s  Update changed local APIs\n\n' "$BOLD" "$RESET"
  while :; do
    prompt "Choose an action" "1"
    case "$ANSWER" in
      1|setup) ACTION="setup"; return ;;
      2|migrate) ACTION="migrate"; return ;;
      3|update) ACTION="update"; return ;;
      *) warn "Choose 1, 2, or 3." ;;
    esac
  done
}

select_target() {
  [ -z "$TARGET" ] || return 0
  printf '  %s1%s  Local development\n' "$BOLD" "$RESET"
  printf '  %s2%s  Production VPS\n\n' "$BOLD" "$RESET"
  while :; do
    prompt "Choose an environment" "1"
    case "$ANSWER" in
      1|local) TARGET="local"; return ;;
      2|vps) TARGET="vps"; return ;;
      *) warn "Choose 1 or 2." ;;
    esac
  done
}

write_local_config() {
  local target="$LOCAL_ROOT/terraform.tfvars"
  local enable_signal dev_mode debug aws_region aws_regions tmp
  if [ -n "$CUSTOM_LOCAL_CONFIG" ]; then
    install_protected_config "$CUSTOM_LOCAL_CONFIG" "$target" "local Terraform configuration"
    return 0
  fi
  prepare_file "$target" "local configuration"
  $WRITE_FILE || return 0

  confirm "Run Signal locally?" yes && enable_signal=true || enable_signal=false
  if [ "$enable_signal" = true ]; then
    if [ -n "$SIGNAL_PRIMARY_REGION_OPTION" ]; then
      valid_signal_region "$SIGNAL_PRIMARY_REGION_OPTION" \
        || die "The Signal primary region must be af-south-1, ap-southeast-1, eu-west-1, or us-east-1."
      aws_region="$SIGNAL_PRIMARY_REGION_OPTION"
    else
      prompt_valid "Signal primary AWS region" "af-south-1" valid_signal_region "Choose af-south-1, ap-southeast-1, eu-west-1, or us-east-1."
      aws_region="$ANSWER"
    fi
    if [ -n "$SIGNAL_REGIONS_OPTION" ]; then
      aws_regions="$SIGNAL_REGIONS_OPTION"
      normalize_signal_regions "$aws_regions" "$aws_region" \
        || die "Signal regions must be a comma-separated subset of af-south-1, ap-southeast-1, eu-west-1, and us-east-1 (or 'all')."
    else
      info "Available Signal regions: af-south-1, ap-southeast-1, eu-west-1, us-east-1"
      while :; do
        prompt "Signal supported AWS regions (comma-separated or all)" "$aws_region"
        aws_regions="$ANSWER"
        normalize_signal_regions "$aws_regions" "$aws_region" && break
        warn "Choose a comma-separated subset of the available regions, or all. The primary region is always included."
      done
    fi
  else
    aws_region="${SIGNAL_PRIMARY_REGION_OPTION:-af-south-1}"
    valid_signal_region "$aws_region" || die "The Signal primary region is not supported."
    normalize_signal_regions "${SIGNAL_REGIONS_OPTION:-$aws_region}" "$aws_region" \
      || die "The configured Signal region selection is not supported."
  fi
  confirm "Use fast development mode with mounted source?" yes && dev_mode=true || dev_mode=false
  confirm "Enable verbose build diagnostics?" no && debug=true || debug=false

  tmp="$(mktemp "$LOCAL_ROOT/.terraform.tfvars.XXXXXX")"
  chmod 600 "$tmp"
  {
    printf '# Managed by infra/setup.sh. Optional integration values can be added manually.\n'
    printf 'enable_signal = %s\n' "$enable_signal"
    printf 'dev_mode     = %s\n' "$dev_mode"
    printf 'debug        = %s\n' "$debug"
    printf 'aws_region = "%s"\n' "$aws_region"
    printf 'signal_supported_regions = %s\n' "$SIGNAL_AWS_REGIONS_JSON"
  } >"$tmp"
  mv "$tmp" "$target"
  success "Wrote local configuration."

  if [ "$dev_mode" = false ] && [ -z "${NPM_TOKEN:-}" ]; then
    if [ -x "$SCRIPT_DIR/scripts/export-build-tokens.sh" ] || [ -r "$SCRIPT_DIR/scripts/export-build-tokens.sh" ]; then
      eval "$(bash "$SCRIPT_DIR/scripts/export-build-tokens.sh" --print)" || die "Set NPM_TOKEN before building production images locally."
    else
      die "Set NPM_TOKEN before building production images locally."
    fi
  fi
}

local_tls_is_current() {
  local certificate_text hostname certificate_modulus key_modulus
  [ -r "$LOCAL_TLS_CERT" ] && [ -r "$LOCAL_TLS_KEY" ] || return 1
  [ -r "$LOCAL_TLS_ROOT_CA" ] || return 1
  openssl x509 -in "$LOCAL_TLS_CERT" -noout -checkend 86400 >/dev/null 2>&1 || return 1
  openssl verify -CAfile "$LOCAL_TLS_ROOT_CA" "$LOCAL_TLS_CERT" >/dev/null 2>&1 || return 1
  certificate_modulus="$(openssl x509 -in "$LOCAL_TLS_CERT" -noout -modulus 2>/dev/null)" || return 1
  key_modulus="$(openssl rsa -in "$LOCAL_TLS_KEY" -noout -modulus 2>/dev/null)" || return 1
  [ "$certificate_modulus" = "$key_modulus" ] || return 1
  certificate_text="$(openssl x509 -in "$LOCAL_TLS_CERT" -noout -text 2>/dev/null)" || return 1
  for hostname in \
    apollodeploy.local \
    '*.apollodeploy.local' \
    api.platform.apollodeploy.local \
    api.signal.apollodeploy.local \
    api.billing.apollodeploy.local; do
    case "$certificate_text" in
      *"DNS:$hostname"*) ;;
      *) return 1 ;;
    esac
  done
}

ensure_local_tls() {
  local ca_root
  section "Local HTTPS"
  require_command mkcert
  require_command openssl
  ca_root="$(mkcert -CAROOT)"
  LOCAL_TLS_ROOT_CA="$ca_root/rootCA.pem"

  if $PLAN_ONLY; then
    if local_tls_is_current; then
      success "The local HTTPS certificate is current."
    else
      info "Setup would install the local CA and generate the HTTPS certificate."
    fi
    return 0
  fi

  mkcert -install
  if local_tls_is_current; then
    success "The trusted local HTTPS certificate is current."
    return 0
  fi

  mkdir -p "$LOCAL_TLS_DIR"
  umask 077
  mkcert \
    -cert-file "$LOCAL_TLS_CERT" \
    -key-file "$LOCAL_TLS_KEY" \
    apollodeploy.local \
    '*.apollodeploy.local' \
    api.platform.apollodeploy.local \
    api.signal.apollodeploy.local \
    api.billing.apollodeploy.local
  chmod 600 "$LOCAL_TLS_KEY"
  chmod 644 "$LOCAL_TLS_CERT"
  success "Generated a trusted local HTTPS certificate."
}

wait_for_local_container() {
  local container="$1"
  local attempt status
  for attempt in $(seq 1 40); do
    status="$(docker inspect --format='{{.State.Health.Status}}' "$container" 2>/dev/null || true)"
    if [ "$status" = "healthy" ]; then
      return 0
    fi
    sleep 3
  done
  docker logs --tail 30 "$container" >&2 || true
  die "$container did not become healthy."
}

verify_local_endpoints() {
  local service hostname path attempt
  local services=(platform billing)
  if [ "$LOCAL_SIGNAL_ENABLED" = "true" ]; then
    services+=(signal)
  fi

  section "Local HTTPS verification"
  docker restart apollo-platform-nginx >/dev/null
  wait_for_local_container apollo-platform-nginx
  for service in "${services[@]}"; do
    hostname="api.${service}.apollodeploy.local"
    path="/health"
    [ "$service" = signal ] && path="/v1/health"
    for attempt in $(seq 1 12); do
      if curl --fail --silent --show-error --max-time 10 \
        --noproxy '*' \
        --cacert "$LOCAL_TLS_ROOT_CA" \
        --resolve "$hostname:443:127.0.0.1" \
        "https://${hostname}${path}" >/dev/null 2>&1; then
        success "https://${hostname}${path}"
        break
      fi
      if [ "$attempt" -eq 12 ]; then
        die "Local HTTPS verification failed for $hostname."
      fi
      sleep 3
    done
  done
}

setup_local() {
  section "Local development"
  for command_name in terraform docker python3 base64 curl; do
    require_command "$command_name"
  done
  require_source_checkout
  guard_legacy_root_identity local
  docker info >/dev/null 2>&1 || die "Docker is not running."
  write_local_config
  ensure_local_tls

  section "Initialize"
  terraform -chdir="$LOCAL_ROOT" init -input=false -no-color
  run_terraform_plan "$LOCAL_ROOT"
  $PLAN_APPLIED || return 0
  read_local_settings

  verify_local_endpoints

  section "Ready"
  terraform -chdir="$LOCAL_ROOT" output services
  success "Local Apollo services are configured and healthy."
}

require_existing_config() {
  local root="$1"
  local label="$2"
  [ -r "$root/terraform.tfvars" ] \
    || die "$label is not configured. Run: bash infra/setup.sh ${label%% *}"
}

initialize_existing_target() {
  case "$TARGET" in
    local)
      guard_legacy_root_identity local
      require_existing_config "$LOCAL_ROOT" "local environment"
      terraform -chdir="$LOCAL_ROOT" init -input=false -no-color
      ;;
    vps)
      guard_legacy_root_identity vps
      require_existing_config "$VPS_ROOT" "vps environment"
      [ -r "$VPS_ROOT/backend.hcl" ] \
        || die "VPS backend is not configured. Run: bash infra/setup.sh vps"
      write_backend_config
      verify_backend_safety
      initialize_vps_terraform
      ;;
    *) die "Unsupported environment: $TARGET" ;;
  esac
}

run_migrations() {
  local reconcile_json

  section "Database migrations"
  if [ "$TARGET" = vps ]; then
    assert_vps_lease_alive
    guard_current_vps_release_provenance
    reconcile_json="$(terraform -chdir="$VPS_ROOT" output -json reconcile)" \
      || die "Could not read the protected VPS reconciliation payload from canonical state."
    printf '%s' "$reconcile_json" \
      | APOLLO_RECONCILE_INTERNAL=setup-v1 \
        bash "$RECONCILE" vps --phase expand --roles reconcile --migrations-only
    unset reconcile_json
    success "Pending backward-compatible VPS expand migrations and grants are applied; contract migrations require the external governed DBA/release process."
  else
    bash "$RECONCILE" "$TARGET" --phase all --roles reconcile --migrations-only
    success "Pending $TARGET migrations and grants are applied."
  fi
}

migrate_services() {
  $PLAN_ONLY && die "Migrations execute directly and do not support --plan-only."
  for command_name in terraform python3 base64; do
    require_command "$command_name"
  done
  require_source_checkout
  if [ "$TARGET" = "local" ]; then
    require_command docker
    docker info >/dev/null 2>&1 || die "Docker is not running."
  else
    for command_name in tar aws jq curl openssl; do
      require_command "$command_name"
    done
  fi

  section "Initialize"
  initialize_existing_target
  if [ "$TARGET" = vps ]; then
    begin_existing_vps_transaction
  fi
  if confirm "Run pending database migrations on $TARGET?" no; then
    run_migrations
  else
    info "Migrations cancelled."
  fi
}

begin_existing_vps_transaction() {
  read_vps_state_list
  [ -n "$VPS_STATE_LIST" ] \
    || die "This hosted operation requires an existing canonical VPS deployment state."
  validate_vps_input_contract
  read_server_config
  verify_aws_account_boundary
  guard_vps_deployment_identity_before_ssh
  verify_ssh
  acquire_vps_lease
  read_vps_state_list
  guard_vps_deployment_identity_before_ssh
  guard_vps_state_against_brownfield_docker
  load_remote_deployment_identity
  $VPS_REMOTE_IDENTITY_PRESENT \
    || die "This hosted operation requires an established remote deployment identity checkpoint."
}

read_local_settings() {
  local expression raw encoded settings_json
  expression='jsonencode({dev_mode=var.dev_mode,enable_signal=var.enable_signal})'
  raw="$(printf '%s\n' "$expression" | terraform -chdir="$LOCAL_ROOT" console -var-file=terraform.tfvars)"
  encoded="$(printf '%s\n' "$raw" | tail -n 1)"
  settings_json="$(printf '%s' "$encoded" | python3 -c 'import json,sys; print(json.loads(sys.stdin.read()))')" \
    || die "Could not read the local Terraform settings."
  LOCAL_DEV_MODE="$(printf '%s' "$settings_json" | python3 -c 'import json,sys; print(str(json.load(sys.stdin)["dev_mode"]).lower())')"
  LOCAL_SIGNAL_ENABLED="$(printf '%s' "$settings_json" | python3 -c 'import json,sys; print(str(json.load(sys.stdin)["enable_signal"]).lower())')"
}

service_has_changes() {
  local service_dir="$1"
  local path="$REPO_ROOT/$service_dir"

  if git -C "$path" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    && [ -n "$(git -C "$path" status --porcelain --untracked-files=normal)" ]; then
    return 0
  fi
  [ -n "$(git -C "$REPO_ROOT" status --porcelain --untracked-files=no -- "$service_dir")" ]
}

detect_changed_services() {
  local service
  CHANGED_SERVICES=()
  for service in platform billing signal; do
    if service_has_changes "apollo-${service}-api"; then
      CHANGED_SERVICES+=("$service")
    fi
  done
}

service_selected() {
  local expected="$1"
  local service
  for service in "${CHANGED_SERVICES[@]}"; do
    [ "$service" = "$expected" ] && return 0
  done
  return 1
}

show_changed_services() {
  local service
  for service in "${CHANGED_SERVICES[@]}"; do
    case "$service" in
      platform) info "Platform API" ;;
      billing) info "Billing API" ;;
      signal) info "Signal API" ;;
    esac
  done
}

filter_disabled_signal() {
  local service
  local enabled_services=()
  for service in "${CHANGED_SERVICES[@]}"; do
    if [ "$service" = "signal" ] && [ "$LOCAL_SIGNAL_ENABLED" != "true" ]; then
      warn "Signal has changes but is disabled in the local Terraform configuration."
    else
      enabled_services+=("$service")
    fi
  done
  CHANGED_SERVICES=("${enabled_services[@]}")
}

wait_for_changed_services() {
  local service container attempt status
  for service in "${CHANGED_SERVICES[@]}"; do
    container="apollo-$service"
    for attempt in $(seq 1 80); do
      status="$(docker inspect --format='{{.State.Health.Status}}' "$container" 2>/dev/null || true)"
      if [ "$status" = "healthy" ]; then
        success "$container is healthy."
        break
      fi
      if [ "$attempt" -eq 80 ]; then
        docker logs --tail 30 "$container" >&2 || true
        die "$container did not become healthy."
      fi
      sleep 5
    done
  done
}

run_update_migrations() {
  if confirm "Run pending migrations before updating the APIs?" yes; then
    TARGET="local"
    run_migrations
  else
    warn "Database migrations were skipped."
  fi
}

ensure_platform_build_token() {
  service_selected platform || return 0
  [ -n "${NPM_TOKEN:-}" ] && return 0
  if [ -r "$SCRIPT_DIR/scripts/export-build-tokens.sh" ]; then
    eval "$(bash "$SCRIPT_DIR/scripts/export-build-tokens.sh" --print)" \
      || die "Set NPM_TOKEN before rebuilding the Platform image."
  else
    die "Set NPM_TOKEN before rebuilding the Platform image."
  fi
  [ -n "${NPM_TOKEN:-}" ] || die "Set NPM_TOKEN before rebuilding the Platform image."
}

update_dev_services() {
  local service containers=()
  section "Local API update"
  show_changed_services
  if $PLAN_ONLY; then
    success "Preview complete; these bind-mounted API containers would be restarted."
    return 0
  fi
  if ! confirm "Rebuild and restart these local API containers?" no; then
    info "Local API update cancelled."
    return 0
  fi

  run_update_migrations
  for service in "${CHANGED_SERVICES[@]}"; do
    containers+=("apollo-$service")
  done
  docker restart "${containers[@]}" >/dev/null
  wait_for_changed_services
  success "Changed local APIs were rebuilt from their mounted source."
}

update_image_services() {
  local service
  local terraform_args=()
  ensure_platform_build_token

  section "Changed local APIs"
  show_changed_services
  for service in "${CHANGED_SERVICES[@]}"; do
    case "$service" in
      platform)
        terraform_args+=(
          '-replace=docker_image.platform[0]'
        )
        ;;
      billing)
        terraform_args+=(
          '-replace=docker_image.billing[0]'
        )
        ;;
      signal)
        terraform_args+=(
          '-replace=docker_image.signal[0]'
        )
        ;;
    esac
  done

  run_terraform_plan "$LOCAL_ROOT" --before-apply run_update_migrations "${terraform_args[@]}"
  $PLAN_APPLIED || return 0
  wait_for_changed_services
  success "Changed local API images and containers are current."
}

update_local_apis() {
  TARGET="local"
  for command_name in terraform docker python3 base64 git; do
    require_command "$command_name"
  done
  require_source_checkout
  guard_legacy_root_identity local
  docker info >/dev/null 2>&1 || die "Docker is not running."
  require_existing_config "$LOCAL_ROOT" "local environment"

  section "Initialize"
  terraform -chdir="$LOCAL_ROOT" init -input=false -no-color
  read_local_settings
  detect_changed_services
  filter_disabled_signal
  if [ "${#CHANGED_SERVICES[@]}" -eq 0 ]; then
    success "No enabled API worktrees have local changes."
    return 0
  fi

  if [ "$LOCAL_DEV_MODE" = "true" ]; then
    update_dev_services
  else
    update_image_services
  fi
}

random_hex() {
  openssl rand -hex "$1"
}

write_bootstrap_backend_block() {
  local tmp

  tmp="$(mktemp "$AWS_BOOTSTRAP_ROOT/.backend.generated.tf.XXXXXX")"
  chmod 600 "$tmp"
  printf '%s\n' 'terraform {' '  backend "s3" {}' '}' >"$tmp"
  mv "$tmp" "$AWS_BOOTSTRAP_BACKEND_BLOCK"
  chmod 600 "$AWS_BOOTSTRAP_BACKEND_BLOCK"
}

bootstrap_aws_prerequisites() {
  local caller_json account_id region deployment_id output_json
  local bootstrap_tmp vps_tmp bootstrap_initialized=false
  local terraform_args=()

  section "AWS bootstrap"
  verify_aws_endpoint_policy
  prepare_vps_terraform_cli_context
  caller_json="$(aws sts get-caller-identity --no-cli-pager --output json)" \
    || die "AWS authentication is unavailable. Reauthenticate with the production operator identity and retry."
  account_id="$(printf '%s' "$caller_json" | jq -er '.Account | select(test("^[0-9]{12}$"))')" \
    || die "Could not derive the authenticated AWS account ID."
  unset caller_json

  if ! confirm "Bootstrap Apollo production prerequisites in AWS account $account_id?" no; then
    die "AWS bootstrap cancelled."
  fi

  if [ -n "$SIGNAL_PRIMARY_REGION_OPTION" ]; then
    valid_signal_region "$SIGNAL_PRIMARY_REGION_OPTION" \
      || die "The bootstrap region must be af-south-1, ap-southeast-1, eu-west-1, or us-east-1."
    region="$SIGNAL_PRIMARY_REGION_OPTION"
  else
    prompt_valid "AWS bootstrap and Signal primary region" "af-south-1" valid_signal_region \
      "Choose af-south-1, ap-southeast-1, eu-west-1, or us-east-1."
    region="$ANSWER"
  fi
  SIGNAL_PRIMARY_REGION_OPTION="$region"

  [ -z "$STATE_BUCKET_OPTION" ] || valid_bucket "$STATE_BUCKET_OPTION" \
    || die "The custom state bucket name is invalid."
  [ "${#OPERATOR_TOPIC_OPTION}" -ge 1 ] \
    && [ "${#OPERATOR_TOPIC_OPTION}" -le 256 ] \
    && [[ "$OPERATOR_TOPIC_OPTION" =~ ^[A-Za-z0-9_-]+$ ]] \
    || die "The operator topic name is invalid."

  if [ -f "$AWS_BOOTSTRAP_BACKEND" ]; then
    write_bootstrap_backend_block
    terraform -chdir="$AWS_BOOTSTRAP_ROOT" init \
      -backend-config="$AWS_BOOTSTRAP_BACKEND" \
      -input=false \
      -lockfile=readonly \
      -no-color
    bootstrap_initialized=true
  else
    rm -f -- "$AWS_BOOTSTRAP_BACKEND_BLOCK"
    terraform -chdir="$AWS_BOOTSTRAP_ROOT" init \
      -reconfigure \
      -input=false \
      -lockfile=readonly \
      -no-color
  fi
  [ "$(terraform -chdir="$AWS_BOOTSTRAP_ROOT" workspace show)" = default ] \
    || die "The AWS bootstrap root selected a non-default Terraform workspace."

  terraform_args+=(
    "-var=account_id=$account_id"
    "-var=region=$region"
    "-var=operator_topic_name=$OPERATOR_TOPIC_OPTION"
  )
  if [ -n "$STATE_BUCKET_OPTION" ]; then
    terraform_args+=("-var=state_bucket_name=$STATE_BUCKET_OPTION")
  fi

  run_terraform_plan "$AWS_BOOTSTRAP_ROOT" "${terraform_args[@]}"
  if ! $PLAN_APPLIED; then
    AWS_BOOTSTRAP_PLANNED=true
    return 0
  fi

  output_json="$(terraform -chdir="$AWS_BOOTSTRAP_ROOT" output -json deployment_inputs)" \
    || die "Could not read the AWS bootstrap outputs."
  deployment_id="$(random_hex 16)"
  bootstrap_tmp="$(mktemp "$AWS_BOOTSTRAP_ROOT/.backend.hcl.XXXXXX")"
  vps_tmp="$(mktemp "$VPS_ROOT/.backend.hcl.XXXXXX")"
  chmod 600 "$bootstrap_tmp" "$vps_tmp"

  python3 - "$bootstrap_tmp" "$vps_tmp" "$deployment_id" 3< <(printf '%s' "$output_json") <<'PY'
import json
import sys

bootstrap_path, vps_path, deployment_id = sys.argv[1:]
values = json.load(open("/dev/fd/3", "r", encoding="utf-8"))

account_id = values["account_id"]
bucket = values["state_bucket"]
region = values["region"]
kms_key = values["state_kms_key_arn"]

def quoted(value):
    return json.dumps(value)

common = f'''bucket       = {quoted(bucket)}
region       = {quoted(region)}
encrypt      = true
use_lockfile = true
kms_key_id   = {quoted(kms_key)}
allowed_account_ids = [{quoted(account_id)}]
'''

with open(bootstrap_path, "w", encoding="utf-8") as target:
    target.write('key          = "apollo/bootstrap/terraform.tfstate"\n' + common)

with open(vps_path, "w", encoding="utf-8") as target:
    target.write(f'''# Generated from the reviewed AWS bootstrap outputs. Keep credentials out.
# apollo_expected_account_id = {quoted(account_id)}
# apollo_deployment_id = {quoted(deployment_id)}
# apollo_state_lineage = "unbound"
# apollo_target_sha256 = "unbound"
key          = "apollo/vps/terraform.tfstate"
{common}''')
PY

  mv "$bootstrap_tmp" "$AWS_BOOTSTRAP_BACKEND"
  mv "$vps_tmp" "$VPS_ROOT/backend.hcl"
  chmod 600 "$AWS_BOOTSTRAP_BACKEND" "$VPS_ROOT/backend.hcl"

  if ! $bootstrap_initialized; then
    write_bootstrap_backend_block
    terraform -chdir="$AWS_BOOTSTRAP_ROOT" init \
      -migrate-state \
      -force-copy \
      -backend-config="$AWS_BOOTSTRAP_BACKEND" \
      -input=false \
      -lockfile=readonly \
      -no-color
  fi

  BOOTSTRAP_AWS_ACCOUNT_ID="$(printf '%s' "$output_json" | jq -er '.account_id')"
  BOOTSTRAP_OPERATOR_ALERT_TOPIC_ARN="$(printf '%s' "$output_json" | jq -er '.operator_alert_topic_arn')"
  unset output_json
  success "AWS state storage and operator-alert topic are ready; backend values were generated automatically."
}

write_backend_config() {
  local target="$VPS_ROOT/backend.hcl"
  local bucket region expected_account_id deployment_id tmp
  if [ -n "$CUSTOM_BACKEND_CONFIG" ]; then
    install_protected_config "$CUSTOM_BACKEND_CONFIG" "$target" "VPS backend configuration"
    read_backend_config "$target"
    return 0
  fi
  if [ ! -f "$target" ] || grep -q 'REPLACE_' "$target"; then
    bootstrap_aws_prerequisites
    $AWS_BOOTSTRAP_PLANNED || read_backend_config "$target"
    return 0
  fi
  prepare_file "$target" "remote-state backend configuration"
  if $WRITE_FILE; then
    prompt_valid "State bucket" "" valid_bucket "Enter an existing S3 bucket name."
    bucket="$ANSWER"
    prompt_valid "State bucket region" "af-south-1" valid_region "Enter an AWS region such as af-south-1."
    region="$ANSWER"
    prompt_valid "Expected state-bucket AWS account ID" "" valid_aws_account_id "Enter the 12-digit account that owns the state bucket."
    expected_account_id="$ANSWER"
    deployment_id="$(random_hex 16)"

    tmp="$(mktemp "$VPS_ROOT/.backend.hcl.XXXXXX")"
    chmod 600 "$tmp"
    APOLLO_SETUP_BUCKET="$bucket" APOLLO_SETUP_KEY="$CANONICAL_VPS_STATE_KEY" \
    APOLLO_SETUP_REGION="$region" APOLLO_SETUP_BACKEND_ACCOUNT="$expected_account_id" \
    APOLLO_SETUP_DEPLOYMENT_ID="$deployment_id" \
      python3 - "$tmp" <<'PY'
import json
import os
import sys

q = lambda name: json.dumps(os.environ[name])
text = f'''# apollo_expected_account_id = {q("APOLLO_SETUP_BACKEND_ACCOUNT")}
# apollo_deployment_id = {q("APOLLO_SETUP_DEPLOYMENT_ID")}
# apollo_state_lineage = "unbound"
# apollo_target_sha256 = "unbound"
bucket       = {q("APOLLO_SETUP_BUCKET")}
key          = {q("APOLLO_SETUP_KEY")}
region       = {q("APOLLO_SETUP_REGION")}
encrypt      = true
use_lockfile = true
allowed_account_ids = [{q("APOLLO_SETUP_BACKEND_ACCOUNT")}]
'''
with open(sys.argv[1], "w", encoding="utf-8") as output:
    output.write(text)
PY
    mv "$tmp" "$target"
    success "Wrote remote-state backend configuration."
  else
    if grep -Eq '^#[[:space:]]*apollo_expected_account_id[[:space:]]*=[[:space:]]*"[0-9]{12}"[[:space:]]*$' "$target"; then
      expected_account_id="$(sed -nE 's/^#[[:space:]]*apollo_expected_account_id[[:space:]]*=[[:space:]]*"([0-9]{12})"[[:space:]]*$/\1/p' "$target")"
    else
      prompt_valid "Expected state-bucket AWS account ID" "" valid_aws_account_id "Enter the 12-digit account that owns the state bucket."
      expected_account_id="$ANSWER"
    fi
    if ! grep -Eq '^#[[:space:]]*apollo_deployment_id[[:space:]]*=[[:space:]]*"[0-9a-f]{32}"[[:space:]]*$' "$target"; then
      deployment_id="$(random_hex 16)"
    else
      deployment_id="$(sed -nE 's/^#[[:space:]]*apollo_deployment_id[[:space:]]*=[[:space:]]*"([0-9a-f]{32})"[[:space:]]*$/\1/p' "$target")"
    fi
    tmp="$(mktemp "$VPS_ROOT/.backend.hcl.XXXXXX")"
    chmod 600 "$tmp"
    APOLLO_SETUP_BACKEND_ACCOUNT="$expected_account_id" \
    APOLLO_SETUP_DEPLOYMENT_ID="$deployment_id" \
      python3 - "$target" "$tmp" <<'PY'
import json
import os
import re
import sys

with open(sys.argv[1], encoding="utf-8") as source:
    existing = source.read()
account = os.environ["APOLLO_SETUP_BACKEND_ACCOUNT"]
deployment_id = os.environ["APOLLO_SETUP_DEPLOYMENT_ID"]
annotations = []
if not re.search(r'^#\s*apollo_expected_account_id\s*=', existing, re.MULTILINE):
    annotations.append(f'# apollo_expected_account_id = {json.dumps(account)}')
if not re.search(r'^#\s*apollo_deployment_id\s*=', existing, re.MULTILINE):
    annotations.append(f'# apollo_deployment_id = {json.dumps(deployment_id)}')
if not re.search(r'^#\s*apollo_state_lineage\s*=', existing, re.MULTILINE):
    annotations.append('# apollo_state_lineage = "unbound"')
if not re.search(r'^#\s*apollo_target_sha256\s*=', existing, re.MULTILINE):
    annotations.append('# apollo_target_sha256 = "unbound"')
if not re.search(r'^\s*allowed_account_ids\s*=', existing, re.MULTILINE):
    existing = existing.rstrip() + f'\nallowed_account_ids = [{json.dumps(account)}]\n'
with open(sys.argv[2], "w", encoding="utf-8") as output:
    if annotations:
        output.write("\n".join(annotations) + "\n")
    output.write(existing)
PY
    mv "$tmp" "$target"
    success "Bound the reused backend configuration to its native account and deployment identity."
  fi

  read_backend_config "$target"
}

read_backend_config() {
  local target="$1"
  local parsed bucket region expected_account_id deployment_id parsed_line_count

  if ! parsed="$(python3 - "$target" <<'PY'
import re
import sys

text = open(sys.argv[1], encoding="utf-8").read()

allowed_keys = {"bucket", "key", "region", "encrypt", "use_lockfile", "kms_key_id", "allowed_account_ids"}
seen_keys = []
for line_number, line in enumerate(text.splitlines(), start=1):
    stripped = line.strip()
    if not stripped or stripped.startswith("#"):
        continue
    assignment = re.fullmatch(r'([a-z_][a-z0-9_]*)\s*=\s*(.+)', stripped)
    if assignment is None:
        raise SystemExit(f"unsupported backend syntax at line {line_number}")
    key_name = assignment.group(1)
    if key_name not in allowed_keys:
        raise SystemExit(f"unsupported backend setting: {key_name}")
    seen_keys.append(key_name)

def required(pattern, label):
    matches = re.findall(pattern, text, flags=re.MULTILINE)
    if len(matches) != 1:
        raise SystemExit(f"expected exactly one literal {label}")
    return matches[0]

bucket = required(r'^\s*bucket\s*=\s*"([^"\r\n]+)"\s*$', "bucket")
key = required(r'^\s*key\s*=\s*"([^"\r\n]+)"\s*$', "key")
region = required(r'^\s*region\s*=\s*"([^"\r\n]+)"\s*$', "region")
account = required(r'^#\s*apollo_expected_account_id\s*=\s*"([0-9]{12})"\s*$', "expected account annotation")
deployment_id = required(r'^#\s*apollo_deployment_id\s*=\s*"([0-9a-f]{32})"\s*$', "deployment identity annotation")
lineage = required(r'^#\s*apollo_state_lineage\s*=\s*"(unbound|[0-9a-f-]{36})"\s*$', "state lineage annotation")
target = required(r'^#\s*apollo_target_sha256\s*=\s*"(unbound|[0-9a-f]{64})"\s*$', "target identity annotation")
encrypt = required(r'^\s*encrypt\s*=\s*(true|false)\s*$', "encrypt setting")
use_lockfile = required(r'^\s*use_lockfile\s*=\s*(true|false)\s*$', "use_lockfile setting")
allowed_account = required(r'^\s*allowed_account_ids\s*=\s*\[\s*"([0-9]{12})"\s*\]\s*$', "allowed_account_ids setting")
if key != "apollo/vps/terraform.tfstate":
    raise SystemExit("state key must be the canonical Apollo VPS key")
if allowed_account != account:
    raise SystemExit("native backend account boundary must match the reviewed annotation")
if encrypt != "true":
    raise SystemExit("backend encryption must be enabled")
if use_lockfile != "true":
    raise SystemExit("S3 lockfile coordination must be enabled")
if "kms_key_id" in seen_keys:
    required(r'^\s*kms_key_id\s*=\s*"([^"\r\n]+)"\s*$', "kms_key_id setting")
print(bucket)
print(region)
print(account)
print(deployment_id)
print(lineage)
print(target)
PY
  )"; then
    die "Could not parse one locked, encrypted, account-bound S3 backend from $target."
  fi
  parsed_line_count="$(printf '%s\n' "$parsed" | awk 'END { print NR }')"
  bucket="$(printf '%s\n' "$parsed" | sed -n '1p')"
  region="$(printf '%s\n' "$parsed" | sed -n '2p')"
  expected_account_id="$(printf '%s\n' "$parsed" | sed -n '3p')"
  deployment_id="$(printf '%s\n' "$parsed" | sed -n '4p')"
  VPS_STATE_LINEAGE="$(printf '%s\n' "$parsed" | sed -n '5p')"
  VPS_TARGET_FINGERPRINT="$(printf '%s\n' "$parsed" | sed -n '6p')"
  [ "$parsed_line_count" -eq 6 ] && [ -n "$bucket" ] && [ -n "$region" ] && [ -n "$expected_account_id" ] && [ -n "$deployment_id" ] \
    || die "Backend configuration parsing returned an unsafe shape."
  valid_bucket "$bucket" || die "Backend configuration contains an invalid S3 bucket name."
  valid_region "$region" || die "Backend configuration contains an invalid AWS region."
  valid_aws_account_id "$expected_account_id" || die "Backend configuration contains an invalid expected account ID."
  BACKEND_BUCKET="$bucket"
  BACKEND_REGION="$region"
  BACKEND_EXPECTED_ACCOUNT_ID="$expected_account_id"
  VPS_DEPLOYMENT_ID="$deployment_id"
}

verify_backend_safety() {
  local identity actual_account location_response actual_region
  local versioning_response encryption_response public_access_response

  verify_aws_endpoint_policy

  [ -n "$BACKEND_BUCKET" ] && [ -n "$BACKEND_REGION" ] \
    && [ -n "$BACKEND_EXPECTED_ACCOUNT_ID" ] \
    || die "Remote-state backend settings were not loaded before safety verification."
  require_command aws
  require_command jq

  section "Remote-state safety"
  identity="$(aws sts get-caller-identity --output json)" \
    || die "Could not verify the AWS identity used for remote state."
  actual_account="$(printf '%s' "$identity" | jq -er '.Account | select(test("^[0-9]{12}$"))')" \
    || die "AWS STS returned an invalid account identity."
  [ "$actual_account" = "$BACKEND_EXPECTED_ACCOUNT_ID" ] \
    || die "AWS credentials resolve to account $actual_account, not the expected state-bucket account $BACKEND_EXPECTED_ACCOUNT_ID."

  location_response="$(aws s3api get-bucket-location \
    --bucket "$BACKEND_BUCKET" \
    --expected-bucket-owner "$BACKEND_EXPECTED_ACCOUNT_ID" \
    --region "$BACKEND_REGION" --output json)" \
    || die "Could not verify ownership and region for state bucket $BACKEND_BUCKET."
  actual_region="$(printf '%s' "$location_response" | jq -r '.LocationConstraint // "us-east-1"')"
  [ "$actual_region" != EU ] || actual_region=eu-west-1
  [ "$actual_region" = "$BACKEND_REGION" ] \
    || die "State bucket $BACKEND_BUCKET is in $actual_region, not configured region $BACKEND_REGION."

  versioning_response="$(aws s3api get-bucket-versioning \
    --bucket "$BACKEND_BUCKET" \
    --expected-bucket-owner "$BACKEND_EXPECTED_ACCOUNT_ID" \
    --region "$BACKEND_REGION" --output json)" \
    || die "Could not verify versioning on state bucket $BACKEND_BUCKET."
  printf '%s' "$versioning_response" | jq -e '.Status == "Enabled"' >/dev/null \
    || die "State bucket $BACKEND_BUCKET must have versioning enabled."

  encryption_response="$(aws s3api get-bucket-encryption \
    --bucket "$BACKEND_BUCKET" \
    --expected-bucket-owner "$BACKEND_EXPECTED_ACCOUNT_ID" \
    --region "$BACKEND_REGION" --output json)" \
    || die "Could not verify default encryption on state bucket $BACKEND_BUCKET."
  printf '%s' "$encryption_response" | jq -e '
    .ServerSideEncryptionConfiguration.Rules
    | length > 0 and all(
        .[];
        .ApplyServerSideEncryptionByDefault.SSEAlgorithm == "AES256" or
        .ApplyServerSideEncryptionByDefault.SSEAlgorithm == "aws:kms"
      )
  ' >/dev/null || die "State bucket $BACKEND_BUCKET must enforce AES-256 or AWS KMS default encryption."

  public_access_response="$(aws s3api get-public-access-block \
    --bucket "$BACKEND_BUCKET" \
    --expected-bucket-owner "$BACKEND_EXPECTED_ACCOUNT_ID" \
    --region "$BACKEND_REGION" --output json)" \
    || die "Could not verify the public-access block on state bucket $BACKEND_BUCKET."
  printf '%s' "$public_access_response" | jq -e '
    .PublicAccessBlockConfiguration
    | .BlockPublicAcls == true and
      .IgnorePublicAcls == true and
      .BlockPublicPolicy == true and
      .RestrictPublicBuckets == true
  ' >/dev/null || die "State bucket $BACKEND_BUCKET must enable all four S3 public-access-block controls."

  success "Remote-state credentials, bucket ownership, region, versioning, encryption, and public-access block are verified."
}

verify_aws_endpoint_policy() {
  local variable_name
  local endpoint_variables=(
    AWS_ENDPOINT_URL
    AWS_ENDPOINT_URL_PREFIX
    AWS_ENDPOINT_URL_SUFFIX
    AWS_ENDPOINT_URL_DYNAMODB
    AWS_DYNAMODB_ENDPOINT
    AWS_ENDPOINT_URL_IAM
    AWS_IAM_ENDPOINT
    AWS_ENDPOINT_URL_S3
    AWS_S3_ENDPOINT
    AWS_ENDPOINT_URL_SSO
    AWS_ENDPOINT_URL_STS
    AWS_STS_ENDPOINT
  )

  for variable_name in "${endpoint_variables[@]}"; do
    if [ -n "${!variable_name:-}" ]; then
      die "AWS endpoint override $variable_name is not allowed for production state or account verification."
    fi
  done
  # Prevent endpoint_url entries in the selected AWS shared-config profile
  # from redirecting either the CLI preflight or Terraform's S3 backend.
  export AWS_IGNORE_CONFIGURED_ENDPOINT_URLS=true
}

guard_vps_terraform_cli_context() {
  local variable_name selected_workspace
  local unsafe_variables=()
  local workspace_file="$VPS_ROOT/.terraform/environment"

  # Production orchestration must not inherit Terraform switches or values
  # from the operator shell. Values are generated or passed explicitly by the
  # wizard after this boundary instead.
  while IFS= read -r variable_name; do
    case "$variable_name" in
      TF_*) ;;
      *) continue ;;
    esac
    unsafe_variables+=("$variable_name")
  done < <(compgen -e)

  if [ "${#unsafe_variables[@]}" -gt 0 ]; then
    die "Production Terraform context is unsafe; unset: ${unsafe_variables[*]}."
  fi

  if [ -e "$workspace_file" ]; then
    [ -f "$workspace_file" ] && [ -r "$workspace_file" ] \
      || die "The cached VPS Terraform workspace selection is not a readable regular file."
    selected_workspace="$(<"$workspace_file")"
    [ "$selected_workspace" = default ] \
      || die "The VPS Terraform root has a cached non-default workspace; select or restore the default workspace before using the production wizard."
  fi
}

prepare_vps_terraform_cli_context() {
  local config_file

  if [ -n "$VPS_TF_CLI_CONFIG_FILE" ]; then
    [ -f "$VPS_TF_CLI_CONFIG_FILE" ] \
      || die "The wizard-owned Terraform CLI configuration disappeared."
    [ "${TF_CLI_CONFIG_FILE:-}" = "$VPS_TF_CLI_CONFIG_FILE" ] \
      || die "The wizard-owned Terraform CLI configuration was replaced."
    return 0
  fi

  guard_vps_terraform_cli_context
  config_file="$(mktemp "${TMPDIR:-/tmp}/apollo-terraform-cli.XXXXXX")"
  chmod 600 "$config_file"
  printf '%s\n' \
    'disable_checkpoint = true' \
    'disable_checkpoint_signature = true' \
    >"$config_file"
  VPS_TF_CLI_CONFIG_FILE="$config_file"
  TF_CLI_CONFIG_FILE="$config_file"
  export TF_CLI_CONFIG_FILE
}

verify_vps_default_workspace() {
  local selected_workspace

  if ! selected_workspace="$(terraform -chdir="$VPS_ROOT" workspace show)"; then
    die "Could not verify the VPS Terraform workspace after backend initialization."
  fi
  [ "$selected_workspace" = default ] \
    || die "The VPS Terraform backend selected a non-default workspace; refusing production state access."
}

initialize_vps_terraform() {
  prepare_vps_terraform_cli_context
  terraform -chdir="$VPS_ROOT" init -reconfigure -input=false -backend-config=backend.hcl -lockfile=readonly -no-color
  verify_vps_default_workspace
}

read_vps_state_list() {
  local state_output raw_state state_lineage

  if state_output="$(terraform -chdir="$VPS_ROOT" state list 2>&1)"; then
    VPS_STATE_LIST="$state_output"
    VPS_STATE_JSON=""
    if [ -n "$VPS_STATE_LIST" ]; then
      raw_state="$(terraform -chdir="$VPS_ROOT" state pull)" \
        || die "Could not pull the canonical VPS state for lineage verification."
      state_lineage="$(printf '%s' "$raw_state" | jq -er '.lineage | select(test("^[0-9a-f-]{36}$"))')" \
        || {
          unset raw_state
          die "The canonical VPS state has no valid immutable lineage."
        }
      VPS_STATE_LINEAGE_ACTUAL="$state_lineage"
      unset raw_state state_lineage
      VPS_STATE_JSON="$(terraform -chdir="$VPS_ROOT" show -json)" \
        || die "Could not inspect canonical VPS state resources for ownership verification."
    else
      VPS_STATE_LINEAGE_ACTUAL=""
    fi
    return 0
  fi

  case "$state_output" in
    *"No state file was found"*|*"No state file found"*)
      VPS_STATE_LIST=""
      VPS_STATE_JSON=""
      VPS_STATE_LINEAGE_ACTUAL=""
      ;;
    *)
      die "Could not read the current VPS Terraform state; refusing to generate credentials or inspect brownfield ownership."
      ;;
  esac
}

validate_vps_input_contract() {
  local result

  # `terraform console` evaluates all variable validation blocks without
  # refreshing providers, connecting to SSH, or proposing infrastructure.
  if ! result="$(printf '%s\n' true \
    | terraform -chdir="$VPS_ROOT" console -var-file="$VPS_VAR_FILE" 2>&1)"; then
    unset result
    die "The VPS configuration failed Terraform's production input contract. No host operation was attempted."
  fi
  [ "$(printf '%s\n' "$result" | tail -n 1)" = true ] \
    || {
      unset result
      die "Terraform did not confirm the VPS input contract. No host operation was attempted."
    }
  unset result
}

vps_target_fingerprint() {
  APOLLO_ID_ACCOUNT="$BACKEND_EXPECTED_ACCOUNT_ID" \
  APOLLO_ID_BUCKET="$BACKEND_BUCKET" \
  APOLLO_ID_KEY="$CANONICAL_VPS_STATE_KEY" \
  APOLLO_ID_HOST="$VPS_HOST" \
  APOLLO_ID_USER="$VPS_USER" \
  APOLLO_ID_PORT="$VPS_PORT" \
  APOLLO_ID_DOMAIN="$VPS_DOMAIN" \
    python3 -c '
import hashlib
import json
import os

identity = {
    "account_id": os.environ["APOLLO_ID_ACCOUNT"],
    "bucket": os.environ["APOLLO_ID_BUCKET"],
    "key": os.environ["APOLLO_ID_KEY"],
    "host": os.environ["APOLLO_ID_HOST"],
    "user": os.environ["APOLLO_ID_USER"],
    "port": int(os.environ["APOLLO_ID_PORT"]),
    "base_domain": os.environ["APOLLO_ID_DOMAIN"],
}
payload = json.dumps(identity, sort_keys=True, separators=(",", ":")).encode()
print(hashlib.sha256(payload).hexdigest())
'
}

write_backend_identity_binding() {
  local lineage="$1"
  local target_fingerprint="$2"
  local target="$VPS_ROOT/backend.hcl"
  local tmp

  tmp="$(mktemp "$VPS_ROOT/.backend.hcl.XXXXXX")"
  chmod 600 "$tmp"
  APOLLO_BIND_LINEAGE="$lineage" APOLLO_BIND_TARGET="$target_fingerprint" \
    python3 - "$target" "$tmp" <<'PY'
import os
import re
import sys

text = open(sys.argv[1], encoding="utf-8").read()
bindings = {
    "apollo_state_lineage": os.environ["APOLLO_BIND_LINEAGE"],
    "apollo_target_sha256": os.environ["APOLLO_BIND_TARGET"],
}
for key, value in bindings.items():
    pattern = rf'^(#\s*{key}\s*=\s*)"[^"]+"\s*$'
    text, count = re.subn(pattern, rf'\g<1>"{value}"', text, count=1, flags=re.MULTILINE)
    if count != 1:
        raise SystemExit(f"missing backend identity binding: {key}")
open(sys.argv[2], "w", encoding="utf-8").write(text)
PY
  mv "$tmp" "$target"
  VPS_STATE_LINEAGE="$lineage"
  VPS_TARGET_FINGERPRINT="$target_fingerprint"
}

guard_vps_deployment_identity_before_ssh() {
  local desired_fingerprint state_connection state_domain
  local state_host state_user state_port

  desired_fingerprint="$(vps_target_fingerprint)" \
    || die "Could not calculate the canonical VPS target identity."
  [[ "$desired_fingerprint" =~ ^[0-9a-f]{64}$ ]] \
    || die "The canonical VPS target identity is malformed."

  if [ "$VPS_TARGET_FINGERPRINT" != unbound ] \
    && [ "$VPS_TARGET_FINGERPRINT" != "$desired_fingerprint" ]; then
    die "The configured host, SSH identity, base domain, or backend coordinates do not match this deployment identity. Host/domain moves require the separate recovery and migration runbook."
  fi

  if [ -n "$VPS_STATE_LIST" ]; then
    [ -n "$VPS_STATE_LINEAGE_ACTUAL" ] \
      || die "A non-empty VPS state has no verified lineage."
    if [ "$VPS_STATE_LINEAGE" != unbound ] \
      && [ "$VPS_STATE_LINEAGE" != "$VPS_STATE_LINEAGE_ACTUAL" ]; then
      die "The remote state lineage does not match this deployment identity. Refusing to operate on a substituted state."
    fi
    state_connection="$(terraform -chdir="$VPS_ROOT" output -json reconcile \
      | jq -ce '.vps | {host, user, ssh_port}')" \
      || die "Existing VPS state has no authoritative target connection output."
    state_domain="$(terraform -chdir="$VPS_ROOT" output -json public_urls \
      | jq -er '.platform_api | capture("^https://api[.]platform[.](?<domain>.+)$").domain')" \
      || die "Existing VPS state has no authoritative base-domain output."
    state_host="$(printf '%s' "$state_connection" | jq -er '.host')"
    state_user="$(printf '%s' "$state_connection" | jq -er '.user')"
    state_port="$(printf '%s' "$state_connection" | jq -er '.ssh_port')"
    unset state_connection
    [ "$state_host" = "$VPS_HOST" ] \
      && [ "$state_user" = "$VPS_USER" ] \
      && [ "$state_port" = "$VPS_PORT" ] \
      && [ "$state_domain" = "$VPS_DOMAIN" ] \
      || die "The configured host, SSH user/port, or base domain differs from canonical state. Normal setup cannot migrate a deployment target."
    unset state_host state_user state_port state_domain
    write_backend_identity_binding "$VPS_STATE_LINEAGE_ACTUAL" "$desired_fingerprint"
  else
    [ "$VPS_STATE_LINEAGE" = unbound ] \
      || die "The backend is bound to a state lineage, but the canonical state is empty. Recover the expected state before continuing."
    write_backend_identity_binding unbound "$desired_fingerprint"
  fi
  success "The canonical state lineage and immutable VPS target identity are bound before SSH."
}

refresh_vps_state_lineage_binding() {
  local raw_state lineage

  raw_state="$(terraform -chdir="$VPS_ROOT" state pull)" \
    || die "Could not pull state after apply to seal its lineage."
  lineage="$(printf '%s' "$raw_state" | jq -er '.lineage | select(test("^[0-9a-f-]{36}$"))')" \
    || {
      unset raw_state
      die "The applied state has no valid lineage."
    }
  unset raw_state
  if [ "$VPS_STATE_LINEAGE" != unbound ] && [ "$VPS_STATE_LINEAGE" != "$lineage" ]; then
    die "The state lineage changed during the deployment transaction."
  fi
  write_backend_identity_binding "$lineage" "$VPS_TARGET_FINGERPRINT"
  VPS_STATE_LINEAGE_ACTUAL="$lineage"
}

write_vps_config() {
  local target="$VPS_ROOT/terraform.tfvars"
  local vps_host vps_user ssh_port ssh_key base_domain tls_email
  local zone_id origin_ipv4 image_user image_token aws_region aws_regions aws_account_id operator_alert_topic_arn tmp
  local render_status
  local platform_digest signal_digest billing_digest
  local platform_commit signal_commit billing_commit
  local custom_vps_path
  VPS_VAR_FILE="$target"
  VPS_CONFIG_COMMIT_REQUIRED=false
  if [ -n "$VPS_STATE_LIST" ]; then
    [ -f "$target" ] || die "The canonical VPS state is non-empty but terraform.tfvars is missing. Refusing to generate replacement credentials; recover the exact deployed values from the approved secret source before continuing."
    if [ -n "$CUSTOM_VPS_CONFIG" ]; then
      custom_vps_path="$(protected_input_file "$CUSTOM_VPS_CONFIG" "VPS Terraform configuration")"
      cmp -s "$custom_vps_path" "$target" \
        || die "The supplied VPS configuration differs from the configuration bound to non-empty state. Stage credential or target changes through the dedicated migration workflow."
    fi
    chmod 600 "$target"
    info "Reusing the existing VPS configuration because the canonical state already owns resources."
    return 0
  fi

  if [ -n "$CUSTOM_VPS_CONFIG" ]; then
    custom_vps_path="$(protected_input_file "$CUSTOM_VPS_CONFIG" "VPS Terraform configuration")"
    tmp="$(mktemp "$VPS_ROOT/.terraform.tfvars.XXXXXX")"
    chmod 600 "$tmp"
    cp "$custom_vps_path" "$tmp"
    chmod 600 "$tmp"
    VPS_CONFIG_CANDIDATE="$tmp"
    VPS_VAR_FILE="$tmp"
    VPS_CONFIG_COMMIT_REQUIRED=true
    success "Staged the supplied VPS configuration pending the remote ownership gate."
    return 0
  fi

  if [ -f "$target" ]; then
    if $NON_INTERACTIVE; then
      chmod 600 "$target"
      info "Reusing $target"
      return 0
    fi
    if confirm "Reuse existing VPS configuration?" yes; then
      chmod 600 "$target"
      info "Reusing $target"
      return 0
    fi
    info "The replacement VPS configuration will remain staged until the remote ownership gate passes."
  fi

  prompt_valid "VPS hostname or IPv4" "" valid_host "Enter a valid hostname or IP address."
  vps_host="$ANSWER"
  prompt_valid "SSH user" "deploy" valid_user "Enter a lowercase Linux user name."
  vps_user="$ANSWER"
  prompt_valid "SSH port" "22" valid_port "Enter a port between 1 and 65535."
  ssh_port="$ANSWER"
  while :; do
    prompt "SSH private key" "$HOME/.ssh/id_ed25519"
    ssh_key="$ANSWER"
    [ -r "$(expand_home "$ssh_key")" ] && break
    warn "The SSH private key is not readable."
  done
  prompt_valid "Base domain" "apollodeploy.com" valid_domain "Enter a valid DNS domain."
  base_domain="$ANSWER"
  prompt_valid "Let's Encrypt email" "ops@$base_domain" valid_email "Enter a valid email address."
  tls_email="$ANSWER"

  prompt_valid "Cloudflare zone ID" "" valid_zone_id "The zone ID must contain 32 hexadecimal characters."
  zone_id="$ANSWER"
  prompt_valid "VPS public IPv4" "$vps_host" valid_ipv4 "Enter the globally routable public unicast IPv4 address of the VPS."
  origin_ipv4="$ANSWER"

  prompt_valid "GHCR user" "" valid_nonempty "A registry user is required."
  image_user="$ANSWER"
  prompt_secret "GHCR read token"
  image_token="$ANSWER"
  select_approved_release
  platform_digest="$(printf '%s' "$APPROVED_RELEASE_JSON" | jq -er '.platform.image | split("@") | .[1]')"
  platform_commit="$(printf '%s' "$APPROVED_RELEASE_JSON" | jq -er '.platform.source_commit')"
  signal_digest="$(printf '%s' "$APPROVED_RELEASE_JSON" | jq -er '.signal.image | split("@") | .[1]')"
  signal_commit="$(printf '%s' "$APPROVED_RELEASE_JSON" | jq -er '.signal.source_commit')"
  billing_digest="$(printf '%s' "$APPROVED_RELEASE_JSON" | jq -er '.billing.image | split("@") | .[1]')"
  billing_commit="$(printf '%s' "$APPROVED_RELEASE_JSON" | jq -er '.billing.source_commit')"
  if [ -n "$SIGNAL_PRIMARY_REGION_OPTION" ]; then
    valid_signal_region "$SIGNAL_PRIMARY_REGION_OPTION" \
      || die "The Signal primary region must be af-south-1, ap-southeast-1, eu-west-1, or us-east-1."
    aws_region="$SIGNAL_PRIMARY_REGION_OPTION"
  else
    prompt_valid "Signal primary AWS region" "af-south-1" valid_signal_region "Choose af-south-1, ap-southeast-1, eu-west-1, or us-east-1."
    aws_region="$ANSWER"
  fi
  if [ -n "$SIGNAL_REGIONS_OPTION" ]; then
    aws_regions="$SIGNAL_REGIONS_OPTION"
    normalize_signal_regions "$aws_regions" "$aws_region" \
      || die "Signal regions must be a comma-separated subset of af-south-1, ap-southeast-1, eu-west-1, and us-east-1 (or 'all')."
  else
    info "Available Signal regions: af-south-1, ap-southeast-1, eu-west-1, us-east-1"
    while :; do
      prompt "Signal supported AWS regions (comma-separated or all)" "$aws_region"
      aws_regions="$ANSWER"
      normalize_signal_regions "$aws_regions" "$aws_region" && break
      warn "Choose a comma-separated subset of the available regions, or all. The primary region is always included."
    done
  fi
  if [ -n "$BOOTSTRAP_AWS_ACCOUNT_ID" ]; then
    aws_account_id="$BOOTSTRAP_AWS_ACCOUNT_ID"
    success "Using AWS account $aws_account_id from the reviewed bootstrap state."
  else
    prompt_valid "Expected AWS account ID" "" valid_aws_account_id "Enter the expected 12-digit AWS account ID."
    aws_account_id="$ANSWER"
  fi
  if [ -n "$BOOTSTRAP_OPERATOR_ALERT_TOPIC_ARN" ]; then
    operator_alert_topic_arn="$BOOTSTRAP_OPERATOR_ALERT_TOPIC_ARN"
    success "Using the operator-alert SNS topic from the reviewed bootstrap state."
  else
    prompt_valid "Operator alert SNS topic ARN" "" valid_sns_topic_arn "Enter an existing operator-owned SNS topic ARN in the Signal account and region."
    operator_alert_topic_arn="$ANSWER"
  fi

  tmp="$(mktemp "$VPS_ROOT/.terraform.tfvars.XXXXXX")"
  chmod 600 "$tmp"
  VPS_CONFIG_CANDIDATE="$tmp"
  VPS_VAR_FILE="$tmp"
  VPS_CONFIG_COMMIT_REQUIRED=true
  render_status=0
  # The renderer receives all values through an inherited pipe. In particular,
  # registry credentials and generated secrets must never appear in a child
  # process environment or argv (both are observable by same-host processes).
  python3 - "$tmp" 3< <(
    printf '%s\0' \
      "$vps_host" \
      "$vps_user" \
      "$ssh_port" \
      "$ssh_key" \
      "$base_domain" \
      "$tls_email" \
      "$zone_id" \
      "$origin_ipv4" \
      "$image_user" \
      "$image_token" \
      "$platform_digest" \
      "$platform_commit" \
      "$signal_digest" \
      "$signal_commit" \
      "$billing_digest" \
      "$billing_commit" \
      "$aws_region" \
      "$SIGNAL_AWS_REGIONS_JSON" \
      "$aws_account_id" \
      "$operator_alert_topic_arn" \
      "$(random_hex 24)" \
      "$(random_hex 24)" \
      "$(random_hex 24)" \
      "$(random_hex 24)" \
      "$(random_hex 24)" \
      "$(random_hex 24)" \
      "$(random_hex 24)" \
      "$(random_hex 24)" \
      "$(random_hex 32)" \
      "$(random_hex 32)" \
      "$(random_hex 32)" \
      "$(random_hex 32)"
  ) <<'PY' || render_status=$?
import json
import os
import sys

names = (
    "host", "user", "port", "key", "domain", "email", "zone", "ipv4",
    "image_user", "image_token", "platform_digest", "platform_commit",
    "signal_digest", "signal_commit", "billing_digest", "billing_commit",
    "aws_region", "signal_regions", "aws_account_id", "operator_alert_topic_arn",
    "db_password", "redis_password",
    "platform_db_password", "billing_db_password",
    "billing_superuser_password", "signal_db_password",
    "signal_superuser_password", "verifier_password", "session_secret",
    "cookie_secret", "internal_secret", "events_signing_secret",
)
raw = os.fdopen(3, "rb").read().split(b"\0")
if raw[-1:] == [b""]:
    raw.pop()
if len(raw) != len(names):
    raise SystemExit("invalid protected configuration payload")
values = {name: value.decode("utf-8") for name, value in zip(names, raw)}
q = lambda name: json.dumps(values[name])
text = f'''environment = "production"

server = {{
  host              = {q("host")}
  user              = {q("user")}
  ssh_port          = {values["port"]}
  ssh_key_path      = {q("key")}
  base_domain       = {q("domain")}
  letsencrypt_email = {q("email")}
}}

cloudflare = {{
  zone_id     = {q("zone")}
  origin_ipv4 = {q("ipv4")}
  proxied     = true
}}

release_manifest = {{
  platform = {{
    image         = {json.dumps("ghcr.io/apollo-deploy/apollo-platform-api@" + values["platform_digest"])}
    source_commit = {q("platform_commit")}
  }}
  signal = {{
    image         = {json.dumps("ghcr.io/apollo-deploy/apollo-signal-api@" + values["signal_digest"])}
    source_commit = {q("signal_commit")}
  }}
  billing = {{
    image         = {json.dumps("ghcr.io/apollo-deploy/apollo-billing-api@" + values["billing_digest"])}
    source_commit = {q("billing_commit")}
  }}
}}

registry_credentials = {{
  username = {q("image_user")}
  token    = {q("image_token")}
}}

database = {{
  password                   = {q("db_password")}
  redis_password             = {q("redis_password")}
  platform_app_password      = {q("platform_db_password")}
  billing_app_password       = {q("billing_db_password")}
  billing_superuser_password = {q("billing_superuser_password")}
  signal_app_password        = {q("signal_db_password")}
  signal_superuser_password  = {q("signal_superuser_password")}
  platform_verifier_password = {q("verifier_password")}
}}

secrets = {{
  session_secret          = {q("session_secret")}
  auth_cookie_secret      = {q("cookie_secret")}
  internal_service_secret = {q("internal_secret")}
}}

aws = {{
  account_id               = {q("aws_account_id")}
  region                   = {q("aws_region")}
  operator_alert_topic_arn = {q("operator_alert_topic_arn")}
}}

signal = {{
  supported_regions     = {json.dumps(json.loads(values["signal_regions"]))}
  events_signing_secret = {q("events_signing_secret")}
  webhook_secret_key    = ""
}}

billing = {{
  polar_api_key        = ""
  polar_webhook_secret = ""
}}

backup = {{
  r2_account_id        = ""
  r2_access_key_id     = ""
  r2_secret_access_key = ""
  r2_bucket            = ""
  restic_password      = ""
}}
'''
with open(sys.argv[1], "w", encoding="utf-8") as output:
    output.write(text)
PY
  unset image_token ANSWER
  if [ "$render_status" -ne 0 ]; then
    rm -f -- "$tmp"
    VPS_CONFIG_CANDIDATE=""
    VPS_CONFIG_COMMIT_REQUIRED=false
    VPS_VAR_FILE="$target"
    die "Could not render the protected VPS configuration payload."
  fi
  success "Staged a mode-0600 VPS configuration pending the remote ownership gate."
}

commit_vps_config() {
  local target="$VPS_ROOT/terraform.tfvars"

  $VPS_CONFIG_COMMIT_REQUIRED || return 0
  [ -n "$VPS_CONFIG_CANDIDATE" ] && [ -f "$VPS_CONFIG_CANDIDATE" ] \
    || die "The staged VPS configuration disappeared before it could be committed."

  if [ -f "$target" ]; then
    backup_file "$target"
  fi
  mv "$VPS_CONFIG_CANDIDATE" "$target"
  chmod 600 "$target"
  VPS_CONFIG_CANDIDATE=""
  VPS_CONFIG_COMMIT_REQUIRED=false
  VPS_VAR_FILE="$target"
  success "Committed the VPS configuration after remote ownership was verified."
}

ensure_cloudflare_token() {
  if [ -n "${CLOUDFLARE_API_TOKEN:-}" ]; then
    success "Cloudflare API token found in the environment."
    return
  fi
  if [ -n "$CLOUDFLARE_TOKEN_FILE" ]; then
    read_protected_secret "$CLOUDFLARE_TOKEN_FILE" "Cloudflare API token file"
    export CLOUDFLARE_API_TOKEN="$ANSWER"
    ANSWER=""
    success "Cloudflare API token loaded from the protected file."
    return
  fi
  prompt_secret "Cloudflare API token"
  export CLOUDFLARE_API_TOKEN="$ANSWER"
  ANSWER=""
}

read_server_config() {
  local expression raw encoded server_json
  expression='jsonencode(local.wizard_server_config)'
  raw="$(printf '%s\n' "$expression" | terraform -chdir="$VPS_ROOT" console -var-file="$VPS_VAR_FILE")"
  encoded="$(printf '%s\n' "$raw" | tail -n 1)"
  server_json="$(printf '%s' "$encoded" | python3 -c 'import json,sys; print(json.loads(sys.stdin.read()))')"

  VPS_HOST="$(printf '%s' "$server_json" | jq -r '.host')"
  VPS_USER="$(printf '%s' "$server_json" | jq -r '.user')"
  VPS_PORT="$(printf '%s' "$server_json" | jq -r '.port')"
  VPS_KEY="$(printf '%s' "$server_json" | jq -r '.key')"
  VPS_DOMAIN="$(printf '%s' "$server_json" | jq -r '.domain')"
  VPS_EMAIL="$(printf '%s' "$server_json" | jq -r '.email')"
  CLOUDFLARE_ZONE_ID="$(printf '%s' "$server_json" | jq -r '.zone')"
  VPS_PROXIED="$(printf '%s' "$server_json" | jq -r '.proxied')"
  VPS_OFFSITE_ENABLED="$(printf '%s' "$server_json" | jq -r '.offsite')"
  VPS_DMARC_ENABLED="$(printf '%s' "$server_json" | jq -r '.dmarc')"
  SIGNAL_AWS_REGION="$(printf '%s' "$server_json" | jq -r '.aws_region')"
  SIGNAL_AWS_REGIONS_JSON="$(printf '%s' "$server_json" | jq -c '.aws_regions')"
  SIGNAL_AWS_ACCOUNT_ID="$(printf '%s' "$server_json" | jq -r '.aws_account_id')"
  DMARC_IDENTITY="$(printf '%s' "$server_json" | jq -r '.dmarc_identity')"
  DMARC_RECEIPT_RULE_SET="$(printf '%s' "$server_json" | jq -r '.dmarc_receipt_rule_set')"
  VPS_KEY_EXPANDED="$(expand_home "$VPS_KEY")"

  [ -r "$VPS_KEY_EXPANDED" ] || die "SSH private key is not readable: $VPS_KEY_EXPANDED"
  VPS_SSH_ARGS=(
    -p "$VPS_PORT"
    -i "$VPS_KEY_EXPANDED"
    -o BatchMode=yes
    -o StrictHostKeyChecking=yes
  )
}

verify_aws_account_boundary() {
  valid_aws_account_id "$BACKEND_EXPECTED_ACCOUNT_ID" \
    || die "The state-backend AWS account boundary is invalid."
  valid_aws_account_id "$SIGNAL_AWS_ACCOUNT_ID" \
    || die "The Signal AWS account boundary is invalid."
  [ "$SIGNAL_AWS_ACCOUNT_ID" = "$BACKEND_EXPECTED_ACCOUNT_ID" ] \
    || die "The canonical wizard requires the state bucket and Signal resources in the same verified AWS account; backend account $BACKEND_EXPECTED_ACCOUNT_ID does not match aws.account_id $SIGNAL_AWS_ACCOUNT_ID."
}

verify_ssh() {
  local known_host="$VPS_HOST"

  case "$known_host" in
    \[*\]) known_host="${known_host#\[}"; known_host="${known_host%\]}" ;;
  esac
  if [ "$VPS_PORT" != 22 ]; then
    known_host="[$known_host]:$VPS_PORT"
  fi

  section "VPS connection"
  if ! ssh "${VPS_SSH_ARGS[@]}" "$VPS_USER@$VPS_HOST" true; then
    die "Strict SSH host-key verification or authentication failed for $VPS_USER@$VPS_HOST. Verify the server fingerprint through the VPS console or provider, add the exact $known_host key to the default OpenSSH known_hosts, and retry. Do not trust a key fetched only over the unverified deployment network."
  fi
  success "SSH connection verified."
}

release_vps_lease() {
  local lease_pid watchdog_pid

  if $VPS_LEASE_FD_OPEN; then
    printf '%s\n' release >&9 2>/dev/null || true
    exec 9>&-
    VPS_LEASE_FD_OPEN=false
  fi
  if [ -n "$VPS_LEASE_PID" ]; then
    lease_pid="$VPS_LEASE_PID"
    # Do not let cleanup hang indefinitely if the SSH transport or remote
    # shell stops consuming the release command. Closing the FIFO normally
    # releases flock; the watchdog bounds a broken transport as well.
    (
      sleep 5
      kill "$lease_pid" >/dev/null 2>&1 || exit 0
      sleep 2
      kill -KILL "$lease_pid" >/dev/null 2>&1 || true
    ) &
    watchdog_pid=$!
    wait "$lease_pid" >/dev/null 2>&1 || true
    kill "$watchdog_pid" >/dev/null 2>&1 || true
    wait "$watchdog_pid" >/dev/null 2>&1 || true
    VPS_LEASE_PID=""
  fi
  if [ -n "$VPS_LEASE_FIFO" ] && [ -p "$VPS_LEASE_FIFO" ]; then
    rm -f -- "$VPS_LEASE_FIFO"
  fi
  if [ -n "$VPS_LEASE_STATUS_FILE" ] && [ -f "$VPS_LEASE_STATUS_FILE" ]; then
    rm -f -- "$VPS_LEASE_STATUS_FILE"
  fi
  if [ -n "$VPS_LEASE_TEMP_DIR" ] && [ -d "$VPS_LEASE_TEMP_DIR" ]; then
    rmdir "$VPS_LEASE_TEMP_DIR" 2>/dev/null || true
  fi
  VPS_LEASE_TEMP_DIR=""
  VPS_LEASE_FIFO=""
  VPS_LEASE_STATUS_FILE=""
}

assert_vps_lease_alive() {
  if [ -z "$VPS_LEASE_PID" ] || ! $VPS_LEASE_FD_OPEN; then
    die "The deployment-wide VPS lease is not held."
  fi
  kill -0 "$VPS_LEASE_PID" >/dev/null 2>&1 \
    || die "The deployment-wide VPS lease connection was lost; refusing further mutation."
  [ "$(sed -n '1p' "$VPS_LEASE_STATUS_FILE" 2>/dev/null || true)" = ACQUIRED ] \
    || die "The deployment-wide VPS lease is no longer confirmed."
}

vps_lease_remote_command() {
  cat <<'REMOTE_LEASE'
set -euo pipefail
deployment_id="$1"
timeout_seconds="$2"
lease_parent="$3"
trusted_uid="$4"
[[ "$deployment_id" =~ ^[0-9a-f]{32}$ ]] || exit 2
[[ "$timeout_seconds" =~ ^[0-9]+$ ]] || exit 2
[[ "$trusted_uid" =~ ^[0-9]+$ ]] || exit 2

stat_uid() {
  stat -c %u "$1" 2>/dev/null || stat -f %u "$1"
}
stat_mode() {
  stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"
}
reject_writable_storage() {
  mode="$1"
  [[ "$mode" =~ ^[0-7]{3,4}$ ]] || return 0
  mode_value=$((8#$mode))
  (( (mode_value & 0022) != 0 ))
}
verify_directory() {
  path="$1"
  expected_mode="${2:-}"
  [ -d "$path" ] && [ ! -L "$path" ] || {
    echo "ERROR: deployment lease directory is missing, not a directory, or a symlink."
    exit 1
  }
  [ "$(stat_uid "$path")" = "$trusted_uid" ] || {
    echo "ERROR: deployment lease directory has an untrusted owner."
    exit 1
  }
  mode="$(stat_mode "$path")"
  ! reject_writable_storage "$mode" || {
    echo "ERROR: deployment lease directory is group/world writable."
    exit 1
  }
  [ -z "$expected_mode" ] || [ "$mode" = "$expected_mode" ] || {
    echo "ERROR: deployment lease directory has an unsafe mode."
    exit 1
  }
}
verify_lock_file() {
  [ -f "$lease_file" ] && [ ! -L "$lease_file" ] || {
    echo "ERROR: deployment lease file is not a regular non-symlink file."
    exit 1
  }
  [ "$(stat_uid "$lease_file")" = "$trusted_uid" ] || {
    echo "ERROR: deployment lease file has an untrusted owner."
    exit 1
  }
  [ "$(stat_mode "$lease_file")" = 600 ] || {
    echo "ERROR: deployment lease file has an unsafe mode."
    exit 1
  }
  links="$(stat -c %h "$lease_file" 2>/dev/null || stat -f %l "$lease_file")"
  [ "$links" = 1 ] || {
    echo "ERROR: deployment lease file has an unsafe hard-link count."
    exit 1
  }
}

verify_directory "$lease_parent"
lease_dir="$lease_parent/apollo-deploy"
if [ -L "$lease_dir" ]; then
  echo "ERROR: deployment lease directory cannot be a symlink."
  exit 1
fi
if [ ! -e "$lease_dir" ]; then
  mkdir -m 700 "$lease_dir" 2>/dev/null || true
fi
verify_directory "$lease_dir" 700
# Apollo owns one Docker/network/marker namespace per VPS, so the lock is
# intentionally host-wide. A second backend/deployment ID cannot bypass it.
lease_file="$lease_dir/vps.lock"
if [ -L "$lease_file" ]; then
  echo "ERROR: deployment lease file cannot be a symlink."
  exit 1
fi
if [ ! -e "$lease_file" ]; then
  (umask 077; set -o noclobber; : >"$lease_file") 2>/dev/null || true
fi
verify_lock_file
command -v flock >/dev/null 2>&1 || {
  echo "ERROR: flock is required for deployment-wide coordination."
  exit 1
}
exec 8>>"$lease_file"
if ! flock -w "$timeout_seconds" 8; then
  echo "ERROR: another Apollo deployment transaction holds the VPS lease."
  exit 75
fi
printf '%s\n' ACQUIRED
while IFS= read -r command; do
  [ "$command" = release ] && exit 0
  echo "ERROR: invalid deployment lease command."
  exit 2
done
REMOTE_LEASE
}

acquire_vps_lease() {
  local attempt status remote_command remote_script_b64 remote_wrapper

  [ -z "$VPS_LEASE_PID" ] \
    || die "The deployment-wide VPS lease was requested twice."
  [[ "$VPS_DEPLOYMENT_ID" =~ ^[0-9a-f]{32}$ ]] \
    || die "A valid deployment identity is required before acquiring the VPS lease."

  VPS_LEASE_TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/apollo-vps-lease.XXXXXX")" \
    || die "Could not allocate the protected VPS lease channel."
  chmod 700 "$VPS_LEASE_TEMP_DIR"
  VPS_LEASE_FIFO="$VPS_LEASE_TEMP_DIR/control"
  VPS_LEASE_STATUS_FILE="$VPS_LEASE_TEMP_DIR/status"
  : >"$VPS_LEASE_STATUS_FILE"
  chmod 600 "$VPS_LEASE_STATUS_FILE"
  mkfifo -m 600 "$VPS_LEASE_FIFO"

  remote_command="$(vps_lease_remote_command)"
  remote_script_b64="$(printf '%s' "$remote_command" | base64 | tr -d '\n')"
  # The single-quoted program is intentionally expanded only by the remote Bash.
  # shellcheck disable=SC2016
  remote_wrapper='set -euo pipefail
script="$(printf "%s" "$1" | base64 --decode)"
shift
if [ "$(id -u)" -eq 0 ]; then
  exec /bin/bash -c "$script" apollo-lease "$@"
fi
command -v sudo >/dev/null 2>&1 && sudo -n true || {
  echo "ERROR: deployment lease requires root or passwordless sudo."
  exit 1
}
exec sudo -n /bin/bash -c "$script" apollo-lease "$@"'
  # The reviewed wrapper and constrained arguments are deliberately assembled locally.
  # shellcheck disable=SC2029
  ssh "${VPS_SSH_ARGS[@]}" "$VPS_USER@$VPS_HOST" \
    "/bin/bash -c '$remote_wrapper' apollo-lease '$remote_script_b64' '$VPS_DEPLOYMENT_ID' 30 /run 0" \
    <"$VPS_LEASE_FIFO" >"$VPS_LEASE_STATUS_FILE" 2>&1 &
  VPS_LEASE_PID=$!
  exec 9>"$VPS_LEASE_FIFO"
  VPS_LEASE_FD_OPEN=true

  for attempt in $(seq 1 60); do
    status="$(sed -n '1p' "$VPS_LEASE_STATUS_FILE" 2>/dev/null || true)"
    if [ "$status" = ACQUIRED ]; then
      assert_vps_lease_alive
      success "Exclusive deployment-wide VPS lease acquired."
      return 0
    fi
    if ! kill -0 "$VPS_LEASE_PID" >/dev/null 2>&1; then
      release_vps_lease
      die "Could not acquire the deployment-wide VPS lease: ${status:-remote lease process exited}."
    fi
    sleep 1
  done
  release_vps_lease
  die "Timed out waiting for the deployment-wide VPS lease."
}

state_has_vps_address() {
  [ -n "${1:-}" ] \
    && printf '%s\n' "$VPS_STATE_LIST" | grep -Fx -- "$1" >/dev/null
}

# Keep this exact list synchronized with the `from` addresses in
# infra/terraform/vps/migrations.tf. Any other legacy address needs an explicit,
# reviewed disposition before the wizard may operate on production state.
is_allowed_legacy_vps_address() {
  case "$1" in
    module.network.docker_network.apollo|\
    module.infra.docker_volume.postgres_data|\
    module.infra.docker_volume.redis_data|\
    module.infra.data.docker_registry_image.postgres|\
    module.infra.data.docker_registry_image.pgbouncer|\
    module.infra.data.docker_registry_image.redis|\
    module.infra.docker_image.postgres|\
    module.infra.docker_image.pgbouncer|\
    module.infra.docker_image.redis|\
    module.infra.docker_container.postgres|\
    module.infra.docker_container.pgbouncer|\
    module.infra.docker_container.redis|\
    module.platform.docker_volume.letsencrypt_certs|\
    module.platform.docker_volume.certbot_webroot|\
    module.platform.docker_image.platform|\
    module.platform.data.docker_registry_image.nginx|\
    module.platform.data.docker_registry_image.certbot|\
    module.platform.docker_image.nginx|\
    module.platform.docker_image.certbot|\
    module.platform.docker_container.platform|\
    module.platform.docker_container.nginx|\
    module.platform.docker_container.certbot|\
    module.signal.docker_image.signal|\
    module.signal.docker_container.signal|\
    module.billing.docker_image.billing|\
    module.billing.docker_container.billing)
      return 0
      ;;
    *) return 1 ;;
  esac
}

# These legacy entries are read-only provider cache records, not remote
# objects. Terraform may forget them without a moved block now that production
# consumes caller-reviewed digest references directly.
is_reviewed_forgotten_legacy_vps_address() {
  case "$1" in
    data.docker_registry_image.platform|\
    data.docker_registry_image.signal|\
    data.docker_registry_image.billing)
      return 0
      ;;
    *) return 1 ;;
  esac
}

is_legacy_vps_namespace_address() {
  case "$1" in
    data.docker_registry_image.*|\
    module.network.*|\
    module.infra.*|\
    module.platform.*|\
    module.signal.*|\
    module.billing.*|\
    module.bootstrap.*)
      return 0
      ;;
    *) return 1 ;;
  esac
}

guard_vps_state_against_brownfield_docker() {
  local remote_inventory comparison_result address state_json inventory_command
  local unknown_legacy_addresses=()

  read_vps_state_list
  if $VPS_CONFIG_COMMIT_REQUIRED && [ -n "$VPS_STATE_LIST" ]; then
    die "The VPS state became non-empty while a new configuration was staged. Refusing to commit generated credentials; rerun with the exact deployed terraform.tfvars."
  fi

  if [ -n "$VPS_STATE_LIST" ]; then
    while IFS= read -r address; do
      if is_legacy_vps_namespace_address "$address" \
        && ! is_allowed_legacy_vps_address "$address" \
        && ! is_reviewed_forgotten_legacy_vps_address "$address"; then
        unknown_legacy_addresses+=("$address")
      fi
    done <<<"$VPS_STATE_LIST"
  fi
  if [ "${#unknown_legacy_addresses[@]}" -gt 0 ]; then
    die "The VPS state contains legacy addresses without an approved move (${unknown_legacy_addresses[*]}). Refusing wizard orchestration until each address has a reviewed disposition."
  fi

  # Docker template expressions must remain literal until the remote Bash runs.
  # shellcheck disable=SC2016
  inventory_command='set -euo pipefail
if ! command -v docker >/dev/null 2>&1; then exit 0; fi
while IFS= read -r name; do
  case "$name" in apollo*) ;; *) continue ;; esac
  id="$(docker container inspect --format "{{.Id}}" "$name")"
  created="$(docker container inspect --format "{{.Created}}" "$name")"
  printf "container\t%s\t%s\t%s\n" "$name" "$id" "$created"
done < <(docker ps --all --format "{{.Names}}")
while IFS= read -r name; do
  case "$name" in apollo*) ;; *) continue ;; esac
  created="$(docker volume inspect --format "{{.CreatedAt}}" "$name")"
  printf "volume\t%s\t%s\t%s\n" "$name" "$name" "$created"
done < <(docker volume ls --format "{{.Name}}")
while IFS= read -r name; do
  case "$name" in apollo*) ;; *) continue ;; esac
  id="$(docker network inspect --format "{{.Id}}" "$name")"
  created="$(docker network inspect --format "{{.Created}}" "$name")"
  printf "network\t%s\t%s\t%s\n" "$name" "$id" "$created"
done < <(docker network ls --format "{{.Name}}")
if docker network inspect apollo >/dev/null 2>&1; then
  docker network inspect --format "{{range .Containers}}{{println .Name}}{{end}}" apollo |
    while IFS= read -r member; do
      [ -z "$member" ] || printf "member\t%s\t-\t-\n" "$member"
    done
fi'
  # The fixed inventory program is deliberately expanded into the remote command.
  # shellcheck disable=SC2029
  remote_inventory="$(ssh "${VPS_SSH_ARGS[@]}" "$VPS_USER@$VPS_HOST" \
    "/bin/bash -c '$inventory_command'")" \
    || die "Could not inspect the VPS Docker inventory; refusing to continue without a complete ownership check."
  unset inventory_command

  state_json="${VPS_STATE_JSON:-}"
  [ -n "$state_json" ] || state_json='{"values":{}}'
  if ! comparison_result="$(printf '%s' "$state_json" \
    | python3 -c '
import json
import re
import sys

inventory_text = sys.argv[1]
state = json.load(sys.stdin)

resources = []
def visit(module):
    resources.extend(module.get("resources", []))
    for child in module.get("child_modules", []):
        visit(child)

root = state.get("values", {}).get("root_module")
if root:
    visit(root)

managed = {}
for resource in resources:
    resource_type = resource.get("type")
    if resource_type not in {"docker_container", "docker_volume", "docker_network"}:
        continue
    values = resource.get("values") or {}
    name = values.get("name")
    if isinstance(name, str) and name:
        managed.setdefault((resource_type.removeprefix("docker_"), name), []).append(resource)

remote = {}
members = []
for line in inventory_text.splitlines():
    parts = line.split("\t")
    if len(parts) != 4 or parts[0] not in {"container", "volume", "network", "member"}:
        raise SystemExit("malformed remote Docker inventory")
    kind, name, object_id, created = parts
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]*", name):
        raise SystemExit("unsafe remote Docker object name")
    if kind == "member":
        members.append(name)
        continue
    key = (kind, name)
    if key in remote:
        raise SystemExit(f"duplicate remote Docker object: {kind}:{name}")
    remote[key] = (object_id, created)

errors = []
for (kind, name), (object_id, _created) in sorted(remote.items()):
    bindings = managed.get((kind, name), [])
    if len(bindings) != 1:
        errors.append(f"{kind}:{name} has {len(bindings)} state bindings")
        continue
    if kind in {"container", "network"}:
        state_id = bindings[0].get("values", {}).get("id")
        if not isinstance(state_id, str) or state_id != object_id:
            errors.append(f"{kind}:{name} immutable ID differs from state")

for (kind, name), bindings in sorted(managed.items()):
    if len(bindings) != 1:
        errors.append(f"{kind}:{name} has duplicate state bindings")
        continue
    if kind == "volume":
        if (kind, name) not in remote:
            errors.append(f"state-tracked durable volume is missing: {name}")
        print("TRACKED\t" + bindings[0]["address"])

for member in sorted(set(members)):
    if len(managed.get(("container", member), [])) != 1:
        errors.append(f"Apollo network has an unowned member: {member}")
    if ("container", member) not in remote:
        errors.append(f"Apollo network member was absent from complete container inventory: {member}")

if errors:
    for error in errors:
        print("ERROR\t" + error)
    raise SystemExit(1)
' "$remote_inventory")"; then
    unset remote_inventory
    die "Live Apollo Docker ownership, immutable IDs, network membership, or durable volumes do not match canonical Terraform state. Refusing apply. ${comparison_result//$'\n'/; }"
  fi
  unset state_json
  unset remote_inventory

  VPS_TRACKED_DURABLE_ADDRESSES=()
  while IFS=$'\t' read -r kind address; do
    [ "$kind" = TRACKED ] && [ -n "$address" ] || continue
    VPS_TRACKED_DURABLE_ADDRESSES+=("$address")
  done <<<"$comparison_result"
  unset comparison_result
}

read_remote_apollo_volume_identities() {
  local remote_command
  # Docker template expressions must remain literal until the remote Bash runs.
  # shellcheck disable=SC2016
  remote_command='set -euo pipefail
command -v docker >/dev/null 2>&1 || exit 0
while IFS= read -r name; do
  case "$name" in apollo*) ;; *) continue ;; esac
  created="$(docker volume inspect --format "{{.CreatedAt}}" "$name")"
  [ -n "$created" ] || {
    echo "ERROR: Docker did not expose a creation identity for volume $name." >&2
    exit 1
  }
  printf "%s\t%s\n" "$name" "$created"
done < <(docker volume ls --format "{{.Name}}")'
  # The fixed volume-identity program is deliberately expanded into the remote command.
  # shellcheck disable=SC2029
  ssh "${VPS_SSH_ARGS[@]}" "$VPS_USER@$VPS_HOST" "/bin/bash -c '$remote_command'"
}

vps_deployment_marker_remote_command() {
  cat <<'REMOTE_MARKER'
set -euo pipefail
operation="$1"
path="$2"
trusted_uid="$3"
[ "$trusted_uid" != self ] || trusted_uid="$(id -u)"
[[ "$trusted_uid" =~ ^[0-9]+$ ]] || exit 2
[[ "$path" = /* ]] || exit 2

stat_uid() {
  stat -c %u "$1" 2>/dev/null || stat -f %u "$1"
}
stat_mode() {
  stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"
}
trusted_owner() {
  owner="$(stat_uid "$1")"
  [ "$owner" = 0 ] || [ "$owner" = "$trusted_uid" ]
}
reject_writable_storage() {
  mode="$1"
  [[ "$mode" =~ ^[0-7]{3,4}$ ]] || return 0
  mode_value=$((8#$mode))
  (( (mode_value & 0022) != 0 ))
}
verify_parent() {
  [ -d "$parent" ] && [ ! -L "$parent" ] || {
    echo "ERROR: deployment marker parent is missing, not a directory, or a symlink." >&2
    exit 1
  }
  trusted_owner "$parent" || {
    echo "ERROR: deployment marker parent has an untrusted owner." >&2
    exit 1
  }
  mode="$(stat_mode "$parent")"
  ! reject_writable_storage "$mode" || {
    echo "ERROR: deployment marker parent is group/world writable." >&2
    exit 1
  }
}
verify_marker() {
  [ -f "$path" ] && [ ! -L "$path" ] || {
    echo "ERROR: deployment identity marker is not a regular non-symlink file." >&2
    exit 1
  }
  trusted_owner "$path" || {
    echo "ERROR: deployment identity marker has an untrusted owner." >&2
    exit 1
  }
  [ "$(stat_mode "$path")" = 600 ] || {
    echo "ERROR: deployment identity marker must have mode 0600." >&2
    exit 1
  }
  links="$(stat -c %h "$path" 2>/dev/null || stat -f %l "$path")"
  [ "$links" = 1 ] || {
    echo "ERROR: deployment identity marker has an unsafe hard-link count." >&2
    exit 1
  }
}

parent="${path%/*}"
if [ "$operation" = read ] && [ ! -e "$parent" ] && [ ! -L "$parent" ]; then
  exit 44
fi
verify_parent
case "$operation" in
  read)
    if [ -L "$path" ]; then
      echo "ERROR: deployment identity marker cannot be a symlink." >&2
      exit 1
    fi
    [ -e "$path" ] || exit 44
    verify_marker
    cat "$path"
    ;;
  write)
    if [ -L "$path" ]; then
      echo "ERROR: deployment identity marker cannot be a symlink." >&2
      exit 1
    fi
    [ ! -e "$path" ] || verify_marker
    umask 077
    marker_tmp="$(mktemp "$parent/.deployment-identity.XXXXXX")"
    trap 'rm -f -- "$marker_tmp"' EXIT
    cat >"$marker_tmp"
    chmod 600 "$marker_tmp"
    trusted_owner "$marker_tmp" || exit 1
    mv -f -- "$marker_tmp" "$path"
    trap - EXIT
    verify_marker
    ;;
  *) exit 2 ;;
esac
REMOTE_MARKER
}

run_remote_deployment_marker() {
  local operation="$1"
  local remote_command remote_script_b64 remote_wrapper

  remote_command="$(vps_deployment_marker_remote_command)"
  remote_script_b64="$(printf '%s' "$remote_command" | base64 | tr -d '\n')"
  # The single-quoted program is intentionally expanded only by the remote Bash.
  # shellcheck disable=SC2016
  remote_wrapper='set -euo pipefail
script="$(printf "%s" "$1" | base64 --decode)"
shift
exec /bin/bash -c "$script" apollo-marker "$@"'
  # The reviewed wrapper and constrained arguments are deliberately assembled locally.
  # shellcheck disable=SC2029
  ssh "${VPS_SSH_ARGS[@]}" "$VPS_USER@$VPS_HOST" \
    "/bin/bash -c '$remote_wrapper' apollo-marker '$remote_script_b64' '$operation' /opt/apollo/.deployment-identity.json self"
}

load_remote_deployment_identity() {
  local marker_json volume_identities parsed marker_status state_json

  VPS_REMOTE_IDENTITY_PRESENT=false
  VPS_LAST_COMPLETE_RELEASE_MANIFEST=""
  if marker_json="$(run_remote_deployment_marker read)"; then
    :
  else
    marker_status=$?
    case "$marker_status" in
      44) return 0 ;;
      *) die "Could not read the protected VPS deployment identity marker." ;;
    esac
  fi
  volume_identities="$(read_remote_apollo_volume_identities)" \
    || die "Could not read durable Docker volume creation identities."
  state_json="${VPS_STATE_JSON:-}"
  [ -n "$state_json" ] || state_json='{"values":{}}'
  if ! parsed="$(printf '%s\0%s' "$marker_json" "$state_json" \
    | python3 -c '
import json
import re
import sys

expected_deployment, expected_lineage, expected_target, inventory = sys.argv[1:]
payload = sys.stdin.buffer.read().split(b"\0")
if len(payload) != 2:
    raise SystemExit("invalid marker/state input framing")
marker = json.loads(payload[0])
state = json.loads(payload[1])
if marker.get("schema") != "apollo-deployment-identity/v1":
    raise SystemExit("unsupported deployment identity schema")
if marker.get("deployment_id") != expected_deployment:
    raise SystemExit("deployment ID mismatch")
if marker.get("target_sha256") != expected_target:
    raise SystemExit("deployment target mismatch")
if expected_lineage and marker.get("state_lineage") != expected_lineage:
    raise SystemExit("state lineage mismatch")
volumes = {}
for line in inventory.splitlines():
    name, created = line.split("\t", 1)
    if not re.fullmatch(r"apollo[A-Za-z0-9_.-]*", name) or not created:
        raise SystemExit("invalid live volume identity")
    if name in volumes:
        raise SystemExit("duplicate live volume identity")
    volumes[name] = created

checkpointed = marker.get("volumes")
if not isinstance(checkpointed, dict):
    raise SystemExit("invalid checkpointed volume identities")
for name, created in checkpointed.items():
    if not re.fullmatch(r"apollo[A-Za-z0-9_.-]*", name) or not isinstance(created, str) or not created:
        raise SystemExit("invalid checkpointed volume identity")
    if volumes.get(name) != created:
        raise SystemExit("durable volume creation identity mismatch")

resources = []
def visit(module):
    resources.extend(module.get("resources", []))
    for child in module.get("child_modules", []):
        visit(child)

root = state.get("values", {}).get("root_module")
if root:
    visit(root)
state_volume_bindings = {}
for resource in resources:
    if resource.get("type") != "docker_volume":
        continue
    name = (resource.get("values") or {}).get("name")
    if isinstance(name, str) and name:
        state_volume_bindings[name] = state_volume_bindings.get(name, 0) + 1
for name in volumes.keys() - checkpointed.keys():
    if state_volume_bindings.get(name) != 1:
        raise SystemExit("additional live volume is not uniquely owned by canonical state")
release = marker.get("last_complete_release")
if release is None:
    print("null")
elif isinstance(release, dict) and sorted(release) == ["billing", "platform", "signal"]:
    print(json.dumps(release, sort_keys=True, separators=(",", ":")))
else:
    raise SystemExit("invalid last-complete release checkpoint")
' "$VPS_DEPLOYMENT_ID" "${VPS_STATE_LINEAGE_ACTUAL:-}" "$VPS_TARGET_FINGERPRINT" "$volume_identities")"; then
    unset marker_json volume_identities parsed state_json
    die "The protected VPS identity marker does not match state, target, or durable-volume creation identities."
  fi
  unset marker_json volume_identities state_json
  VPS_REMOTE_IDENTITY_PRESENT=true
  if [ "$parsed" != null ]; then
    VPS_LAST_COMPLETE_RELEASE_MANIFEST="$parsed"
  fi
  unset parsed
  success "Remote deployment and durable-volume identities match their protected checkpoint."
}

write_remote_deployment_identity() {
  local release_json="${1:-null}"
  local volume_identities marker_json lineage

  assert_vps_lease_alive
  lineage="${VPS_STATE_LINEAGE_ACTUAL:-unbound}"
  [ -n "$lineage" ] || lineage=unbound
  volume_identities="$(read_remote_apollo_volume_identities)" \
    || die "Could not capture durable Docker volume creation identities."
  marker_json="$(printf '%s' "$release_json" \
    | python3 -c '
import json
import re
import sys

deployment_id, lineage, target, inventory = sys.argv[1:]
release = json.load(sys.stdin)
if release is not None and not (
    isinstance(release, dict) and sorted(release) == ["billing", "platform", "signal"]
):
    raise SystemExit("invalid release checkpoint")
volumes = {}
for line in inventory.splitlines():
    name, created = line.split("\t", 1)
    if not re.fullmatch(r"apollo[A-Za-z0-9_.-]*", name) or not created:
        raise SystemExit("invalid volume identity")
    volumes[name] = created
marker = {
    "schema": "apollo-deployment-identity/v1",
    "deployment_id": deployment_id,
    "state_lineage": lineage,
    "target_sha256": target,
    "volumes": volumes,
    "last_complete_release": release,
}
print(json.dumps(marker, sort_keys=True, separators=(",", ":")))
' "$VPS_DEPLOYMENT_ID" "$lineage" "$VPS_TARGET_FINGERPRINT" "$volume_identities")" \
    || die "Could not construct the protected VPS deployment identity marker."
  unset volume_identities
  printf '%s\n' "$marker_json" \
    | run_remote_deployment_marker write \
    || {
      unset marker_json
      die "Could not write the protected VPS deployment identity marker."
    }
  unset marker_json
  VPS_REMOTE_IDENTITY_PRESENT=true
  [ "$release_json" = null ] || VPS_LAST_COMPLETE_RELEASE_MANIFEST="$release_json"
}

ensure_remote_deployment_identity_before_mutation() {
  load_remote_deployment_identity
  $VPS_REMOTE_IDENTITY_PRESENT && return 0

  if [ -n "$VPS_STATE_LIST" ]; then
    $PLAN_ONLY \
      && die "This brownfield VPS has no durable deployment-identity checkpoint. Run the full wizard to review and establish the one-time adoption before using plan-only mode."
    confirm "Adopt the exact state-bound Docker IDs and durable-volume creation identities into this deployment checkpoint?" no \
      || die "Brownfield deployment identity adoption was not approved."
    if vps_state_has_application_container; then
      # A partial first apply after adoption must retain the known all-old
      # checkpoint. Prove the raw state-recorded release and exact live
      # RepoDigests before it becomes the last-complete identity.
      guard_current_vps_release_provenance
      [ -n "$VPS_VERIFIED_CURRENT_RELEASE_MANIFEST" ] \
        || die "Could not establish a verified last-complete release for brownfield adoption."
      write_remote_deployment_identity "$VPS_VERIFIED_CURRENT_RELEASE_MANIFEST"
    else
      write_remote_deployment_identity null
    fi
    success "Established the one-time brownfield deployment identity checkpoint."
  fi
}

guard_vps_durable_plan() {
  local plan_file="$1"
  local tracked_json dangerous_changes

  if [ "${#VPS_TRACKED_DURABLE_ADDRESSES[@]}" -gt 0 ]; then
    tracked_json="$(printf '%s\n' "${VPS_TRACKED_DURABLE_ADDRESSES[@]}" \
      | jq -Rsc 'split("\n") | map(select(length > 0))')"
    if ! dangerous_changes="$(
      terraform -chdir="$VPS_ROOT" show -json "$plan_file" \
        | jq -r --argjson tracked "$tracked_json" '
            .resource_changes[]?
            | select(.address as $address | $tracked | index($address))
            | select(
                (.change.actions | index("create")) or
                (.change.actions | index("delete"))
              )
            | "\(.address): \(.change.actions | join(","))"
          '
    )"; then
      die "Could not inspect the saved VPS plan for durable-volume lifecycle changes."
    fi
    if [ -n "$dangerous_changes" ]; then
      die "The saved plan would create, replace, or delete a durable volume that was already tracked before planning ($dangerous_changes). Refusing apply; preserve or recover the existing volume and re-plan."
    fi
    success "The saved plan does not create, replace, or delete any previously tracked durable volume."
  fi
  guard_vps_sns_subscription_plan "$plan_file"
  guard_vps_release_sources "$plan_file"
  guard_vps_database_identity_plan "$plan_file"
}

guard_vps_sns_subscription_plan() {
  local plan_file="$1"
  local replacement_actions desired_endpoint

  $VPS_PLAN_GUARD_SNS || return 0
  if $SNS_REPLACEMENT_ALLOWED; then
    desired_endpoint="https://api.signal.${VPS_DOMAIN}/v1/ses-events/ingest"
    if ! terraform -chdir="$VPS_ROOT" show -json "$plan_file" \
      | jq -ce --arg endpoint "$desired_endpoint" '
          [.resource_changes[]?
            | select(any(.change.actions[]; . == "create" or . == "update" or . == "delete"))
            | {
                address,
                actions: .change.actions,
                endpoint: .change.after.endpoint,
                protocol: .change.after.protocol
              }]
          | select(length > 0)
          | select(all(.[].address;
              . == "aws_sns_topic_subscription.signal_ses_events[0]" or
              startswith("aws_sns_topic_subscription.regional_signal_ses_events[")
            ))
          | select(all(.[].actions;
              . == ["create"] or . == ["delete", "create"] or . == ["update"]
            ))
          | select(all(.[]; .endpoint == $endpoint and .protocol == "https"))
        ' >/dev/null; then
      die "The post-TLS saved plan must change exactly the Signal HTTPS SNS subscription to the reverified endpoint."
    fi
    return 0
  fi
  if ! replacement_actions="$(
    terraform -chdir="$VPS_ROOT" show -json "$plan_file" \
      | jq -r '
          .resource_changes[]?
          | select(
              .address == "aws_sns_topic_subscription.signal_ses_events[0]" or
              (.address | startswith("aws_sns_topic_subscription.regional_signal_ses_events["))
            )
          | select(.change.actions | index("delete"))
          | .change.actions | join(",")
        '
  )"; then
    die "Could not inspect the saved VPS plan for an SES feedback subscription replacement."
  fi
  [ -z "$replacement_actions" ] \
    || die "The saved plan would replace the SES feedback subscription before its new TLS endpoint is ready ($replacement_actions). Refusing the first-stage apply."
}

verify_deferred_sns_endpoint_before_apply() {
  assert_vps_lease_alive
  [ -n "$PLAN_FILE" ] && [ -f "$PLAN_FILE" ] \
    || die "The exact post-TLS SNS saved plan disappeared before apply."
  guard_vps_sns_subscription_plan "$PLAN_FILE"
  verify_public_endpoints
}

read_current_sns_subscription_endpoint() {
  local address='aws_sns_topic_subscription.signal_ses_events[0]'

  SNS_CURRENT_ENDPOINT=""
  terraform -chdir="$VPS_ROOT" state show "$address" >/dev/null 2>&1 \
    || return 1
  if ! SNS_CURRENT_ENDPOINT="$(
    terraform -chdir="$VPS_ROOT" show -json \
      | jq -er --arg address "$address" '
          [.. | objects | select(.address? == $address) | .values.endpoint]
          | if length == 1 then .[0] else error("subscription address count") end
          | select(test("^https://api[.]signal[.][A-Za-z0-9.-]+/v1/ses-events/ingest$"))
        '
  )"; then
    die "Could not read one safe current SES feedback subscription endpoint from Terraform state."
  fi
}

vps_state_has_application_container() {
  local address

  for address in \
    module.deployment.module.application_plane.module.platform.docker_container.platform \
    'module.deployment.module.application_plane.module.signal[0].docker_container.signal' \
    module.deployment.module.application_plane.module.billing.docker_container.billing \
    module.deployment.module.platform.docker_container.platform \
    'module.deployment.module.signal[0].docker_container.signal' \
    module.deployment.module.billing.docker_container.billing \
    module.platform.docker_container.platform \
    module.signal.docker_container.signal \
    module.billing.docker_container.billing; do
    state_has_vps_address "$address" && return 0
  done
  return 1
}

capture_current_vps_release_manifest() {
  local release_output

  VPS_CURRENT_RELEASE_MANIFEST=""
  if ! release_output="$(
    terraform -chdir="$VPS_ROOT" output -json \
      | jq -ce '
          if has("release_manifest")
          then {
            present: true,
            value: .release_manifest.value
          }
          else {present: false}
          end
        '
  )"; then
    die "Could not inspect state outputs before planning; refusing to infer the running release from recomputed saved-plan outputs."
  fi
  if [ "$(printf '%s' "$release_output" | jq -r '.present')" = false ]; then
    unset release_output
    return 0
  fi
  if ! VPS_CURRENT_RELEASE_MANIFEST="$(
    printf '%s' "$release_output" \
      | jq -ce '
          .value
          | select(
              type == "object" and
              (keys == ["billing", "platform", "signal"]) and
              all(to_entries[];
                (.value | type == "object" and keys == ["image", "source_commit"]) and
                (.value.image | type == "string") and
                (.value.source_commit | type == "string" and test("^[0-9a-f]{40}$"))
              )
            )
        '
  )"; then
    unset release_output
    die "The state-recorded release manifest is malformed; refusing to infer live image identity."
  fi
  unset release_output
}

ensure_vps_live_check_connection() {
  local connection_json

  if [ -n "${VPS_HOST:-}" ] && [ -n "${VPS_USER:-}" ] \
    && [ -n "${VPS_PORT:-}" ] && [ -n "${VPS_KEY_EXPANDED:-}" ]; then
    return 0
  fi
  if ! connection_json="$(
    terraform -chdir="$VPS_ROOT" output -json reconcile \
      | jq -ce '
          .vps
          | {
              host: .host,
              user: .user,
              ssh_port: .ssh_port,
              ssh_key_path: .ssh_key_path
            }
        '
  )"; then
    die "Could not read the state-recorded VPS connection for live release verification."
  fi
  VPS_HOST="$(printf '%s' "$connection_json" | jq -er '.host')"
  VPS_USER="$(printf '%s' "$connection_json" | jq -er '.user')"
  VPS_PORT="$(printf '%s' "$connection_json" | jq -er '.ssh_port')"
  VPS_KEY="$(printf '%s' "$connection_json" | jq -er '.ssh_key_path')"
  unset connection_json
  valid_host "$VPS_HOST" || die "State contains an unsafe VPS host for live release verification."
  valid_user "$VPS_USER" || die "State contains an unsafe VPS user for live release verification."
  valid_port "$VPS_PORT" || die "State contains an unsafe VPS port for live release verification."
  VPS_KEY_EXPANDED="$(expand_home "$VPS_KEY")"
  [ -r "$VPS_KEY_EXPANDED" ] \
    || die "State-recorded SSH private key is not readable: $VPS_KEY_EXPANDED"
  VPS_SSH_ARGS=(
    -p "$VPS_PORT"
    -i "$VPS_KEY_EXPANDED"
    -o BatchMode=yes
    -o StrictHostKeyChecking=yes
  )
}

verify_live_vps_release_images() {
  local releases_json="$1"
  local platform_image signal_image billing_image

  platform_image="$(printf '%s' "$releases_json" | jq -er '.platform.image')"
  signal_image="$(printf '%s' "$releases_json" | jq -er '.signal.image')"
  billing_image="$(printf '%s' "$releases_json" | jq -er '.billing.image')"
  ensure_vps_live_check_connection

  if ! ssh "${VPS_SSH_ARGS[@]}" "$VPS_USER@$VPS_HOST" /bin/bash -s -- \
    platform apollo-platform "$platform_image" \
    signal apollo-signal "$signal_image" \
    billing apollo-billing "$billing_image" \
    < "$LIVE_RELEASE_IMAGE_VERIFIER"; then
    die "A running VPS application container does not match its reviewed immutable release digest; refusing database mutation."
  fi
  success "Running VPS application containers match their reviewed immutable release digests."
}

verify_live_vps_release_transition() {
  local previous_releases_json="$1"
  local desired_releases_json="$2"
  local plan_file="$3"
  local service previous_image desired_image container remote_command command_args
  local repairable_missing_json allow_missing

  [ -n "$previous_releases_json" ] || {
    verify_live_vps_release_images "$desired_releases_json"
    return 0
  }
  ensure_vps_live_check_connection
  [ -n "$plan_file" ] && [ -f "$plan_file" ] \
    || die "The exact saved plan is unavailable for interrupted-release verification."
  if ! repairable_missing_json="$(terraform -chdir="$VPS_ROOT" show -json "$plan_file" \
    | jq -ce '
        def repairable($address; $name):
          any(.resource_changes[]?;
            .address == $address and
            .type == "docker_container" and
            (.change.actions | index("create")) and
            .change.after.name == $name
          );
        {
          platform: (repairable("module.deployment.module.application_plane.module.platform.docker_container.platform"; "apollo-platform") or repairable("module.deployment.module.platform.docker_container.platform"; "apollo-platform")),
          signal: (repairable("module.deployment.module.application_plane.module.signal[0].docker_container.signal"; "apollo-signal") or repairable("module.deployment.module.signal[0].docker_container.signal"; "apollo-signal")),
          billing: (repairable("module.deployment.module.application_plane.module.billing.docker_container.billing"; "apollo-billing") or repairable("module.deployment.module.billing.docker_container.billing"; "apollo-billing"))
        }
      ')"; then
    die "Could not derive missing-container repair authority from the exact saved plan."
  fi
  command_args=""
  for service in platform signal billing; do
    previous_image="$(printf '%s' "$previous_releases_json" | jq -er --arg service "$service" '.[$service].image')"
    desired_image="$(printf '%s' "$desired_releases_json" | jq -er --arg service "$service" '.[$service].image')"
    case "$service:$previous_image:$desired_image" in
      platform:ghcr.io/apollo-deploy/apollo-platform-api@sha256:*:ghcr.io/apollo-deploy/apollo-platform-api@sha256:*) container=apollo-platform ;;
      signal:ghcr.io/apollo-deploy/apollo-signal-api@sha256:*:ghcr.io/apollo-deploy/apollo-signal-api@sha256:*) container=apollo-signal ;;
      billing:ghcr.io/apollo-deploy/apollo-billing-api@sha256:*:ghcr.io/apollo-deploy/apollo-billing-api@sha256:*) container=apollo-billing ;;
      *) die "A release transition contains a non-canonical Apollo image repository." ;;
    esac
    [[ "$previous_image" =~ @sha256:[0-9a-f]{64}$ ]] \
      && [[ "$desired_image" =~ @sha256:[0-9a-f]{64}$ ]] \
      || die "A release transition contains a malformed immutable image digest."
    allow_missing="$(printf '%s' "$repairable_missing_json" | jq -er --arg service "$service" '.[$service] | if . then "true" else "false" end')"
    command_args="$command_args $service $container $previous_image $desired_image $allow_missing"
  done
  unset repairable_missing_json allow_missing

  # Docker template expressions must remain literal until the remote Bash runs.
  # shellcheck disable=SC2016
  remote_command='set -euo pipefail
command -v docker >/dev/null 2>&1
docker info >/dev/null 2>&1
while [ "$#" -gt 0 ]; do
  service="$1"
  container="$2"
  previous="$3"
  desired="$4"
  allow_missing="$5"
  shift 5
  case "$service:$container" in
    platform:apollo-platform|signal:apollo-signal|billing:apollo-billing) ;;
    *) exit 2 ;;
  esac
  case "$allow_missing" in true|false) ;; *) exit 2 ;; esac
  if ! live_id="$(docker container inspect --format "{{.Image}}" "$container" 2>/dev/null)"; then
    if [ "$allow_missing" = true ]; then
      echo "INFO: $container is missing and the exact saved plan recreates its canonical resource."
      continue
    fi
    echo "ERROR: $container is missing without an exact saved-plan create action." >&2
    exit 1
  fi
  [[ "$live_id" =~ ^sha256:[0-9a-f]{64}$ ]] || exit 1
  matched=false
  for expected in "$previous" "$desired"; do
    expected_id="$(docker image inspect --format "{{.Id}}" "$expected" 2>/dev/null || true)"
    [ "$live_id" = "$expected_id" ] || continue
    while IFS= read -r repo_digest; do
      [ "$repo_digest" = "$expected" ] && matched=true
    done < <(docker image inspect --format "{{range .RepoDigests}}{{println .}}{{end}}" "$live_id")
  done
  $matched || {
    echo "ERROR: $container is neither the last-complete nor the desired reviewed release." >&2
    exit 1
  }
done'
  # Every interpolated argument above is constrained to a service token,
  # canonical container name, or lowercase digest reference without spaces.
  # The fixed transition program and constrained digest arguments are assembled locally.
  # shellcheck disable=SC2029
  if ! ssh "${VPS_SSH_ARGS[@]}" "$VPS_USER@$VPS_HOST" \
    "/bin/bash -c '$remote_command' apollo-release-transition$command_args"; then
    unset command_args remote_command
    die "The VPS is not a resumable mixture of the last-complete and current desired releases."
  fi
  unset command_args remote_command
  success "Each live application is either the last-complete or current desired immutable release; interrupted apply retry is safe."
}

guard_vps_release_sources() {
  local plan_file="$1"
  local desired_releases_json current_releases_json
  local platform_commit signal_commit billing_commit

  $VPS_PLAN_GUARD_RELEASE || return 0
  if ! desired_releases_json="$(
    terraform -chdir="$VPS_ROOT" show -json "$plan_file" \
      | jq -ce '.variables.release_manifest.value'
  )"; then
    die "Could not derive the immutable release from the exact saved plan."
  fi

  verify_approved_release_manifest "$desired_releases_json"
  platform_commit="$(printf '%s' "$desired_releases_json" | jq -er '.platform.source_commit')"
  signal_commit="$(printf '%s' "$desired_releases_json" | jq -er '.signal.source_commit')"
  billing_commit="$(printf '%s' "$desired_releases_json" | jq -er '.billing.source_commit')"
  /bin/bash "$RELEASE_SOURCE_VERIFIER" \
    platform "$REPO_ROOT/apollo-platform-api" "$platform_commit" \
    signal "$REPO_ROOT/apollo-signal-api" "$signal_commit" \
    billing "$REPO_ROOT/apollo-billing-api" "$billing_commit" \
    || {
      unset desired_releases_json
      die "The exact saved plan is not backed by three clean, commit-matched service checkouts."
    }

  if [ -n "$VPS_LAST_COMPLETE_RELEASE_MANIFEST" ]; then
    current_releases_json="$VPS_LAST_COMPLETE_RELEASE_MANIFEST"
  elif [ -n "$VPS_CURRENT_RELEASE_MANIFEST" ]; then
    current_releases_json="$VPS_CURRENT_RELEASE_MANIFEST"
  else
    current_releases_json=""
  fi
  if [ -n "$current_releases_json" ]; then
    if [ "$current_releases_json" != "$desired_releases_json" ]; then
      verify_approved_release_manifest "$current_releases_json"
    fi
    verify_live_vps_release_transition "$current_releases_json" "$desired_releases_json" "$plan_file"
    unset current_releases_json
  elif vps_state_has_application_container; then
    info "The migrated state has no prior release output; proving the saved-plan manifest directly against every running application container."
    verify_live_vps_release_images "$desired_releases_json"
  fi
  unset desired_releases_json
}

guard_current_vps_release_provenance() {
  local releases_json

  VPS_VERIFIED_CURRENT_RELEASE_MANIFEST=""

  if ! releases_json="$(terraform -chdir="$VPS_ROOT" output -json release_manifest)"; then
    die "Could not read the currently deployed release manifest from VPS state; use the normal VPS deploy wizard to establish a verified release before migrating."
  fi
  verify_approved_release_manifest "$releases_json"
  verify_live_vps_release_images "$releases_json"
  VPS_VERIFIED_CURRENT_RELEASE_MANIFEST="$releases_json"
  unset releases_json
  success "The live GHCR digests match a state-recorded CI-approved release."
}

verify_dmarc_receiving_identity() {
  local response verification_status active_response active_rule_set

  [ "$VPS_DMARC_ENABLED" = true ] || return 0
  require_command aws
  [ -n "$DMARC_RECEIPT_RULE_SET" ] \
    || die "DMARC ingestion is enabled without a configured SES receipt rule set."
  section "DMARC receiving prerequisites"
  response="$(aws ses get-identity-verification-attributes \
    --region "$SIGNAL_AWS_REGION" \
    --identities "$DMARC_IDENTITY" \
    --output json)" || die "Could not query the SES receiving identity $DMARC_IDENTITY in $SIGNAL_AWS_REGION."
  verification_status="$(printf '%s' "$response" | jq -r --arg identity "$DMARC_IDENTITY" '.VerificationAttributes[$identity].VerificationStatus // "Missing"')"
  [ "$verification_status" = Success ] || die "SES identity $DMARC_IDENTITY is not verified in $SIGNAL_AWS_REGION (status: $verification_status). Verify it before enabling DMARC ingestion."
  active_response="$(aws ses describe-active-receipt-rule-set \
    --region "$SIGNAL_AWS_REGION" \
    --output json)" || die "Could not query the active SES receipt rule set in $SIGNAL_AWS_REGION."
  active_rule_set="$(printf '%s' "$active_response" | jq -r '.Metadata.Name // "Missing"')"
  [ "$active_rule_set" = "$DMARC_RECEIPT_RULE_SET" ] \
    || die "SES receipt rule set $DMARC_RECEIPT_RULE_SET is not active in $SIGNAL_AWS_REGION (active: $active_rule_set). Activate the operator-owned set before enabling DMARC ingestion."
  success "SES identity $DMARC_IDENTITY is verified and receipt rule set $DMARC_RECEIPT_RULE_SET is active."
}

acknowledge_backup_scope() {
  [ "$VPS_OFFSITE_ENABLED" = true ] && return 0
  warn "Offsite PostgreSQL backup upload is disabled; the configured backup volume remains on the same VPS as the database."
  $PLAN_ONLY && return 0
  confirm "Proceed while explicitly accepting same-host-only recovery risk?" no \
    || die "Production apply cancelled. Configure backup.r2_* values or explicitly accept the residual risk."
}

read_backup_health_status() {
  local container_name="$1"

  ssh "${VPS_SSH_ARGS[@]}" \
    -o ConnectTimeout=10 \
    -o ServerAliveInterval=10 -o ServerAliveCountMax=2 \
    "$VPS_USER@$VPS_HOST" bash -s -- "$container_name" <<'REMOTE'
set -euo pipefail
container_name="$1"
docker inspect "$container_name" >/dev/null 2>&1
docker inspect --format '{{if .State.Restarting}}restarting{{else}}{{if .State.Paused}}paused{{else}}{{if .State.Running}}{{if .State.Health}}{{.State.Health.Status}}{{else}}no-healthcheck{{end}}{{else}}{{.State.Status}}{{end}}{{end}}{{end}}' "$container_name"
REMOTE
}

verify_backup_health() {
  local container_name health_status now deadline remaining sleep_seconds
  local all_healthy pending_containers
  local healthy_containers='|'
  local announced_wait=false
  local backup_containers=(apollo-postgres-backup)
  [ "$VPS_OFFSITE_ENABLED" = true ] && backup_containers+=(apollo-postgres-backup-offsite)

  section "Backup health"
  now="$(date +%s)"
  deadline=$((now + BACKUP_HEALTH_TIMEOUT_SECONDS))
  while :; do
    all_healthy=true
    pending_containers=""
    for container_name in "${backup_containers[@]}"; do
      if ! health_status="$(read_backup_health_status "$container_name")"; then
        die "Backup container $container_name is missing or could not be inspected."
      fi

      case "$health_status" in
        healthy)
          case "$healthy_containers" in
            *"|$container_name|"*) ;;
            *)
              healthy_containers="${healthy_containers}${container_name}|"
              success "$container_name is healthy."
              ;;
          esac
          ;;
        starting|restarting|created)
          all_healthy=false
          pending_containers="${pending_containers}${pending_containers:+, }$container_name ($health_status)"
          ;;
        unhealthy|exited|dead|removing|paused|no-healthcheck)
          die "$container_name has failed backup readiness ($health_status); the deployment is not ready for recovery operations."
          ;;
        *)
          die "$container_name has no usable health status ($health_status)."
          ;;
      esac
    done

    $all_healthy && return 0
    if ! $announced_wait; then
      info "Waiting up to $BACKUP_HEALTH_TIMEOUT_SECONDS seconds for every required backup container to become healthy."
      announced_wait=true
    fi
    now="$(date +%s)"
    if [ "$now" -ge "$deadline" ]; then
      die "Backup readiness timed out with containers still pending: $pending_containers."
    fi
    remaining=$((deadline - now))
    sleep_seconds="$BACKUP_HEALTH_POLL_SECONDS"
    [ "$sleep_seconds" -le "$remaining" ] || sleep_seconds="$remaining"
    sleep "$sleep_seconds"
  done
}

adopt_cloudflare_records() {
  local service hostname address response count record_id record_type errors
  section "Cloudflare DNS"
  for service in platform billing signal; do
    hostname="api.${service}.${VPS_DOMAIN}"
    address="module.cloudflare_dns.cloudflare_dns_record.api[\"${service}\"]"
    if terraform -chdir="$VPS_ROOT" state list 2>/dev/null | grep -Fxq "$address"; then
      success "$hostname is already managed by Terraform."
      continue
    fi

    response="$(
      printf 'Authorization: Bearer %s\nContent-Type: application/json\n' \
        "$CLOUDFLARE_API_TOKEN" \
        | curl --fail --silent --show-error --get \
          --header @- \
          --data-urlencode "name=$hostname" \
          "https://api.cloudflare.com/client/v4/zones/$CLOUDFLARE_ZONE_ID/dns_records"
    )" \
      || die "Cloudflare DNS lookup failed for $hostname."
    if [ "$(printf '%s' "$response" | jq -r '.success')" != true ]; then
      errors="$(printf '%s' "$response" | jq -r '[.errors[].message] | join("; ")')"
      die "Cloudflare rejected the DNS lookup for $hostname: $errors"
    fi

    count="$(printf '%s' "$response" | jq -r '.result | length')"
    if [ "$count" -eq 0 ]; then
      info "$hostname will be created."
      continue
    fi
    [ "$count" -eq 1 ] || die "Multiple Cloudflare records exist for $hostname; resolve them before setup."
    record_type="$(printf '%s' "$response" | jq -r '.result[0].type')"
    [ "$record_type" = A ] || die "$hostname already exists as $record_type; an A record is required."
    record_id="$(printf '%s' "$response" | jq -r '.result[0].id')"

    if confirm "Adopt the existing $hostname record into Terraform?" yes; then
      assert_vps_lease_alive
      terraform -chdir="$VPS_ROOT" import \
        -var-file="$VPS_VAR_FILE" "$address" "$CLOUDFLARE_ZONE_ID/$record_id"
      success "Imported $hostname."
    else
      die "$hostname must be imported or removed before Terraform can create it."
    fi
  done
}

verify_public_endpoints() {
  local failed=0
  local service path url attempt verified
  section "Public verification"
  for service in platform billing signal; do
    path="/health"
    [ "$service" = signal ] && path="/v1/health"
    url="https://api.${service}.${VPS_DOMAIN}${path}"
    verified=false
    for attempt in $(seq 1 12); do
      if curl --fail --silent --show-error --max-time 20 "$url" >/dev/null 2>&1; then
        verified=true
        break
      fi
      sleep 5
    done
    if $verified; then
      success "$url"
    else
      warn "$url did not return a successful response."
      failed=1
    fi
  done
  [ "$failed" -eq 0 ] || die "One or more public health checks failed."
}

verify_certbot_renewal_health() {
  local attempt health_status

  section "Certificate renewal health"
  for attempt in $(seq 1 24); do
    assert_vps_lease_alive
    health_status="$(ssh "${VPS_SSH_ARGS[@]}" "$VPS_USER@$VPS_HOST" \
      "docker inspect --format='{{if .State.Health}}{{.State.Health.Status}}{{else}}no-healthcheck{{end}}' apollo-platform-certbot" 2>/dev/null || true)"
    case "$health_status" in
      healthy)
        success "Certbot renewal and certificate-expiry health are current."
        return 0
        ;;
      unhealthy|no-healthcheck|exited|dead)
        die "Certbot renewal readiness failed closed ($health_status)."
        ;;
    esac
    sleep 5
  done
  die "Certbot renewal readiness did not become healthy after TLS setup."
}

build_vps_predeploy_reconcile_json() {
  local plan_file="$1"

  terraform -chdir="$VPS_ROOT" show -json "$plan_file" \
    | jq -ce '
        {
          transport: "ssh",
          postgres_container: "apollo-platform-postgres",
          platform_container: "apollo-platform",
          billing_container: "apollo-billing",
          signal_container: "apollo-signal",
          enable_signal: true,
          vps: {
            host: .variables.server.value.host,
            user: .variables.server.value.user,
            ssh_port: .variables.server.value.ssh_port,
            ssh_key_path: .variables.server.value.ssh_key_path
          },
          release: {
            platform: {
              source_commit: .variables.release_manifest.value.platform.source_commit
            },
            signal: {
              source_commit: .variables.release_manifest.value.signal.source_commit
            },
            billing: {
              source_commit: .variables.release_manifest.value.billing.source_commit
            }
          },
          database: {
            user: .variables.database.value.user,
            password: .variables.database.value.password,
            name: .variables.database.value.name,
            signal_name: "apollo_deploy_signal",
            roles: {
              platform_app: .variables.database.value.platform_app_password,
              billing_app: .variables.database.value.billing_app_password,
              billing_superuser: .variables.database.value.billing_superuser_password,
              signal_app: .variables.database.value.signal_app_password,
              signal_superuser: .variables.database.value.signal_superuser_password,
              platform_verifier: .variables.database.value.platform_verifier_password
            }
          },
          oauth_clients: {}
        }
      '
}

vps_database_identity_fingerprint() {
  python3 -c '
import hashlib
import sys

sys.stdout.write(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())
'
}

guard_vps_database_identity_plan() {
  local plan_file="$1"
  local current_identity_fingerprint planned_identity_fingerprint credential_changes

  vps_postgres_is_tracked || return 0

  [ -n "$plan_file" ] && [ -f "$plan_file" ] \
    || die "The exact saved plan is unavailable for the database identity guard."

  if ! current_identity_fingerprint="$(
    terraform -chdir="$VPS_ROOT" output -json reconcile \
      | jq -ceS '
          .database
          | {user, password, name, signal_name, roles}
          | if (
              (.user | type) == "string" and (.user | length) > 0 and
              (.password | type) == "string" and (.password | length) > 0 and
              (.name | type) == "string" and (.name | length) > 0 and
              (.signal_name | type) == "string" and (.signal_name | length) > 0 and
              (.roles | type) == "object" and
              (.roles | keys == ["billing_app", "billing_superuser", "platform_app", "platform_verifier", "signal_app", "signal_superuser"]) and
              all(.roles[]; type == "string" and length > 0)
            ) then . else error("invalid current database identity") end
        ' \
      | vps_database_identity_fingerprint
  )"; then
    die "Could not read the current PostgreSQL identity from canonical VPS state; refusing a brownfield apply."
  fi

  if ! planned_identity_fingerprint="$(
    terraform -chdir="$VPS_ROOT" show -json "$plan_file" \
      | jq -ceS '
          {
            user: .variables.database.value.user,
            password: .variables.database.value.password,
            name: .variables.database.value.name,
            signal_name: "apollo_deploy_signal",
            roles: {
              platform_app: .variables.database.value.platform_app_password,
              billing_app: .variables.database.value.billing_app_password,
              billing_superuser: .variables.database.value.billing_superuser_password,
              signal_app: .variables.database.value.signal_app_password,
              signal_superuser: .variables.database.value.signal_superuser_password,
              platform_verifier: .variables.database.value.platform_verifier_password
            }
          }
          | if (
              (.user | type) == "string" and (.user | length) > 0 and
              (.password | type) == "string" and (.password | length) > 0 and
              (.name | type) == "string" and (.name | length) > 0 and
              (.signal_name | type) == "string" and (.signal_name | length) > 0 and
              all(.roles[]; type == "string" and length > 0)
            ) then . else error("invalid planned database identity") end
        ' \
      | vps_database_identity_fingerprint
  )"; then
    unset current_identity_fingerprint
    die "Could not read the planned PostgreSQL identity from the exact saved plan."
  fi

  if [ "$current_identity_fingerprint" != "$planned_identity_fingerprint" ]; then
    unset current_identity_fingerprint planned_identity_fingerprint
    die "The saved plan changes a PostgreSQL root/scoped credential or init-only database identity. Ordinary deploys cannot safely split credentials across a partial apply; use a separately reviewed versioned credential-cutover procedure."
  fi
  unset current_identity_fingerprint planned_identity_fingerprint

  if ! credential_changes="$(terraform -chdir="$VPS_ROOT" show -json "$plan_file" \
    | jq -r '
        def resources($module):
          ($module.resources // []) +
          [($module.child_modules // [])[] | resources(.)[]];
        def critical_env($root):
          [resources($root)[]
            | select(.type == "docker_container")
            | select(.values.name as $name | [
                "apollo-platform-postgres",
                "apollo-platform-pgbouncer",
                "apollo-platform-redis",
                "apollo-platform",
                "apollo-signal",
                "apollo-billing"
              ] | index($name))
            | {
                address,
                env: [(.values.env // [])[]
                  | select(test("^(.*(PASSWORD|SECRET|TOKEN|ACCESS_KEY)|PLATFORM_CLIENT_ID|OAUTH_.*_IDS)="))]
                  | sort
              }]
          | sort_by(.address);
        (critical_env(.prior_state.values.root_module)) as $prior
        | (critical_env(.planned_values.root_module)) as $planned
        | if $prior != $planned then
            "security-critical container credentials or shared authentication values change"
          else empty end,
        (.resource_changes[]?
          | select(.type == "random_password" or .type == "random_string" or .type == "random_uuid")
          | select(.change.before != null)
          | select(.change.actions != ["no-op"])
          | "existing OAuth identity resource changes: \(.address) (\(.change.actions | join(",")))")
      ')"; then
    die "Could not compare brownfield runtime credentials in the exact saved plan."
  fi
  if [ -n "$credential_changes" ]; then
    unset credential_changes
    die "The saved plan rotates runtime, shared, or OAuth credentials in an ordinary release. Use a separately reviewed versioned cutover that tolerates partial application."
  fi
  unset credential_changes
}

vps_postgres_is_tracked() {
  local address

  for address in \
    'module.deployment.module.data_plane.module.infrastructure.docker_container.postgres' \
    'module.deployment.module.data_plane.docker_volume.postgres_data[0]' \
    'module.deployment.module.infra.docker_container.postgres' \
    'module.infra.docker_container.postgres' \
    'module.deployment.docker_volume.postgres_data[0]' \
    'module.infra.docker_volume.postgres_data'; do
    if state_has_vps_address "$address"; then
      return 0
    fi
  done
  return 1
}

run_vps_predeploy_migrations() {
  local reconcile_json

  vps_postgres_is_tracked || return 0
  assert_vps_lease_alive

  [ -n "$PLAN_FILE" ] && [ -f "$PLAN_FILE" ] \
    || die "The exact saved plan is unavailable for pre-deploy migration inputs."
  # The same invariant already ran as an after-plan guard, including in
  # plan-only mode. Repeat it immediately before mutation as defense in depth.
  guard_vps_database_identity_plan "$PLAN_FILE"
  if ! reconcile_json="$(build_vps_predeploy_reconcile_json "$PLAN_FILE")"; then
    die "Could not derive pre-deploy migration inputs from the exact saved plan."
  fi

  section "Pre-deploy database migrations"
  if ! printf '%s' "$reconcile_json" \
    | APOLLO_RECONCILE_INTERNAL=setup-v1 \
      bash "$RECONCILE" vps --phase expand --roles skip --migrations-only; then
    unset reconcile_json
    die "Pre-deploy database migrations failed; the saved infrastructure plan was not applied."
  fi
  unset reconcile_json
  success "Backward-compatible migrations are current before application containers change."
}

run_vps_postapply_reconciliation() {
  local reconcile_json

  assert_vps_lease_alive
  reconcile_json="$(terraform -chdir="$VPS_ROOT" output -json reconcile)" \
    || die "Could not read the applied VPS reconciliation payload from canonical state."
  printf '%s' "$reconcile_json" \
    | APOLLO_RECONCILE_INTERNAL=setup-v1 \
      bash "$RECONCILE" vps --phase expand --roles reconcile
  unset reconcile_json
  success "The release is running on the backward-compatible schema; all contract migrations remain deferred."
}

setup_vps() {
  local desired_sns_endpoint completed_release_json

  section "Production VPS"
  for command_name in terraform python3 base64 tar openssl ssh rsync curl jq aws; do
    require_command "$command_name"
  done
  require_source_checkout
  guard_legacy_root_identity vps
  write_backend_config
  if $AWS_BOOTSTRAP_PLANNED; then
    info "AWS bootstrap plan completed; VPS planning requires the reviewed bootstrap plan to be applied first."
    return 0
  fi
  verify_backend_safety

  section "Initialize"
  initialize_vps_terraform
  read_vps_state_list
  write_vps_config
  validate_vps_input_contract
  read_server_config
  verify_aws_account_boundary
  guard_vps_deployment_identity_before_ssh
  verify_ssh
  acquire_vps_lease
  read_vps_state_list
  guard_vps_deployment_identity_before_ssh
  guard_vps_state_against_brownfield_docker
  ensure_remote_deployment_identity_before_mutation
  commit_vps_config
  ensure_cloudflare_token
  acknowledge_backup_scope
  verify_dmarc_receiving_identity

  if $PLAN_ONLY; then
    info "Plan-only mode skips VPS bootstrap and Terraform state imports."
  else
    section "VPS host policy"
    assert_vps_lease_alive
    if [ "$VPS_PROXIED" = true ]; then
      bash "$BOOTSTRAP" -p "$VPS_PORT" -i "$VPS_KEY_EXPANDED" "$VPS_USER@$VPS_HOST"
    else
      bash "$BOOTSTRAP" -d -p "$VPS_PORT" -i "$VPS_KEY_EXPANDED" "$VPS_USER@$VPS_HOST"
    fi
    success "VPS bootstrap and origin-access policy are current."
    if ! $VPS_REMOTE_IDENTITY_PRESENT; then
      write_remote_deployment_identity null
      success "Established the greenfield deployment identity checkpoint."
    fi
    adopt_cloudflare_records
  fi

  # A new or replacement HTTPS SNS subscription is staged only after Signal's
  # desired public TLS endpoint is healthy. During a domain change, retain the
  # exact old endpoint through the first saved plan instead of destroying it.
  VPS_PLAN_GUARD_SNS=true
  VPS_PLAN_GUARD_RELEASE=true
  desired_sns_endpoint="https://api.signal.${VPS_DOMAIN}/v1/ses-events/ingest"
  if ! $PLAN_ONLY && read_current_sns_subscription_endpoint; then
    if [ "$SNS_CURRENT_ENDPOINT" != "$desired_sns_endpoint" ]; then
      die "The existing SES feedback endpoint differs from the immutable deployment domain. Use the target-migration runbook; normal setup cannot stage a base-domain move."
    else
      run_terraform_plan "$VPS_ROOT" \
        --after-plan guard_vps_durable_plan \
        --before-apply run_vps_predeploy_migrations \
        -var-file="$VPS_VAR_FILE"
    fi
  elif ! $PLAN_ONLY; then
    SNS_SUBSCRIPTION_DEFERRED=true
    run_terraform_plan "$VPS_ROOT" \
      --after-plan guard_vps_durable_plan \
      --before-apply run_vps_predeploy_migrations \
      -var-file="$VPS_VAR_FILE" \
      -var=enable_ses_feedback_subscription=false
  else
    run_terraform_plan "$VPS_ROOT" \
      --after-plan guard_vps_durable_plan \
      --before-apply run_vps_predeploy_migrations \
      -var-file="$VPS_VAR_FILE"
  fi
  $PLAN_APPLIED || return 0
  refresh_vps_state_lineage_binding
  guard_current_vps_release_provenance

  section "Database and OAuth"
  run_vps_postapply_reconciliation
  success "Migrations and OAuth clients are registered and current."

  section "TLS"
  bash "$SETUP_TLS" -p "$VPS_PORT" -i "$VPS_KEY_EXPANDED" \
    "$VPS_USER@$VPS_HOST" "$VPS_DOMAIN" "$VPS_EMAIL"
  verify_public_endpoints
  verify_certbot_renewal_health

  if $SNS_SUBSCRIPTION_DEFERRED; then
    section "SES feedback subscription"
    SNS_REPLACEMENT_ALLOWED=true
    run_terraform_plan "$VPS_ROOT" \
      --after-plan guard_vps_durable_plan \
      --before-apply verify_deferred_sns_endpoint_before_apply \
      -var-file="$VPS_VAR_FILE"
    $PLAN_APPLIED || die "The SES feedback subscription was not applied. Delivery metrics will remain incomplete."
  fi

  verify_backup_health
  completed_release_json="$(terraform -chdir="$VPS_ROOT" output -json release_manifest)" \
    || die "Could not checkpoint the completed VPS release manifest."
  write_remote_deployment_identity "$completed_release_json"
  unset completed_release_json
  section "Ready"
  terraform -chdir="$VPS_ROOT" output public_urls
  success "The hosted Apollo APIs are deployed."
}

main() {
  if $NON_INTERACTIVE; then
    [ -n "$ACTION" ] && [ -n "$TARGET" ] \
      || die "Non-interactive mode requires an explicit action and target."
  else
    require_tty
  fi
  banner
  select_action
  select_target

  if [ -n "$CUSTOM_LOCAL_CONFIG" ] && { [ "$ACTION" != setup ] || [ "$TARGET" != local ]; }; then
    die "--local-config is only valid for local setup."
  fi
  if { [ -n "$CUSTOM_VPS_CONFIG" ] || [ -n "$CUSTOM_BACKEND_CONFIG" ] || [ -n "$STATE_BUCKET_OPTION" ] \
    || [ "$OPERATOR_TOPIC_OPTION" != "apollo-production-operator-alerts" ] || [ -n "$CLOUDFLARE_TOKEN_FILE" ]; } \
    && { [ "$ACTION" != setup ] || [ "$TARGET" != vps ]; }; then
    die "VPS configuration, backend, and Cloudflare token overrides are only valid for VPS setup."
  fi

  case "$ACTION" in
    setup)
      case "$TARGET" in
        local) setup_local ;;
        vps) setup_vps ;;
        *) die "Unsupported setup target: $TARGET" ;;
      esac
      ;;
    migrate)
      migrate_services
      ;;
    update)
      [ "$TARGET" != "vps" ] || die "API image updates are local-only; VPS deploys use published immutable images."
      update_local_apis
      ;;
    *) die "Unsupported action: $ACTION" ;;
  esac
}

if [ "${APOLLO_SETUP_LIBRARY_ONLY:-false}" != true ]; then
  main
fi
