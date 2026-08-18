#!/usr/bin/env bash

load_vps_target() {
  ensure_vps_public_config
  require_command ssh
  VPS_HOST="$(env_value "$VPS_PUBLIC_FILE" VPS_HOST)"
  VPS_USER="$(env_value "$VPS_PUBLIC_FILE" VPS_USER)"
  VPS_PORT="$(env_value "$VPS_PUBLIC_FILE" VPS_SSH_PORT 22)"
  VPS_KEY="$(env_value "$VPS_PUBLIC_FILE" VPS_SSH_KEY)"
  VPS_KNOWN_HOSTS="$(env_value "$VPS_PUBLIC_FILE" VPS_KNOWN_HOSTS)"
  VPS_EXPECTED_MACHINE_ID="$(env_value "$VPS_PUBLIC_FILE" VPS_MACHINE_ID)"
  [[ "$VPS_HOST" =~ ^[A-Za-z0-9.-]+$ && "$VPS_USER" =~ ^[A-Za-z_][A-Za-z0-9_-]*$ ]] \
    || die 'Invalid VPS SSH target.'
  [[ "$VPS_PORT" =~ ^[0-9]+$ && "$VPS_PORT" -ge 1 && "$VPS_PORT" -le 65535 ]] \
    || die 'VPS_SSH_PORT is invalid.'
  [[ "$VPS_KEY" == /* && "$VPS_KNOWN_HOSTS" == /* ]] \
    || die 'VPS_SSH_KEY and VPS_KNOWN_HOSTS must be absolute paths.'
  require_protected_file "$VPS_KEY" 'VPS SSH private key'
  [[ -f "$VPS_KNOWN_HOSTS" && ! -L "$VPS_KNOWN_HOSTS" ]] \
    || die 'VPS known_hosts file is unavailable or unsafe.'
  VPS_SSH=(ssh -F none -p "$VPS_PORT" -i "$VPS_KEY"
    -o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes
    -o "UserKnownHostsFile=$VPS_KNOWN_HOSTS" -o ClearAllForwardings=yes
    -o PermitLocalCommand=no -o RequestTTY=no "$VPS_USER@$VPS_HOST")
}

vps_ssh() {
  local argument quoted remote_command=''
  for argument in "$@"; do
    quoted="'${argument//\'/\'\\\'\'}'"
    remote_command+="${remote_command:+ }$quoted"
  done
  "${VPS_SSH[@]}" "$remote_command"
}

verify_vps_target() {
  local actual_machine_id
  load_vps_target
  actual_machine_id="$(vps_ssh cat /etc/machine-id)" || die 'Could not read the VPS machine identity.'
  [[ "$actual_machine_id" =~ ^[0-9a-f]{32}$ ]] || die 'VPS returned an invalid machine identity.'
  if [[ "$VPS_EXPECTED_MACHINE_ID" == SET_DURING_SETUP ]]; then
    printf 'Target VPS\n  Host        %s:%s\n  User        %s\n  Machine ID  %s\n' \
      "$VPS_HOST" "$VPS_PORT" "$VPS_USER" "$actual_machine_id"
    confirm_target 'Bind this exact native VPS machine identity?'
    replace_env_value "$VPS_PUBLIC_FILE" VPS_MACHINE_ID "$actual_machine_id"
    VPS_EXPECTED_MACHINE_ID="$actual_machine_id"
  fi
  [[ "$actual_machine_id" == "$VPS_EXPECTED_MACHINE_ID" ]] \
    || die "Wrong VPS machine identity: expected $VPS_EXPECTED_MACHINE_ID, received $actual_machine_id"
}

assert_trusted_infrastructure() {
  [[ "${APOLLO_TESTING:-false}" != true ]] || return 0
  require_command git
  local head remote_main
  [[ -z "$(git -C "$REPO_ROOT" status --porcelain --untracked-files=all -- \
    infra .github/workflows/terraform.yaml)" ]] \
    || die 'Production mutation requires clean, tracked infrastructure files.'
  head="$(git -C "$REPO_ROOT" rev-parse HEAD)"
  remote_main="$(git -C "$REPO_ROOT" ls-remote --exit-code origin refs/heads/main | awk 'NR == 1 { print $1 }')" \
    || die 'Could not verify the current protected origin/main revision.'
  [[ "$head" == "$remote_main" ]] \
    || die 'Production mutation requires the exact current origin/main revision.'
}

selected_release_json() {
  [[ -n "$RELEASE_ID" ]] || die 'Production commands require --release ID.'
  [[ "$RELEASE_ID" =~ ^[a-z0-9][a-z0-9._-]{0,63}$ ]] || die 'Invalid release ID.'
  jq -cer --arg id "$RELEASE_ID" '.releases[] | select(.id == $id)' \
    "$SCRIPT_DIR/releases/approved-releases.json" \
    || die "Release is not approved: $RELEASE_ID"
}

verify_selected_release() {
  local release_json="$1"
  local services username token
  services="$(jq -c '.services' <<<"$release_json")"
  printf '%s' "$services" \
    | "$SCRIPT_DIR/scripts/lib/verify-approved-release.sh" "$SCRIPT_DIR/releases/approved-releases.json"
  username="$(env_value "$VPS_SECRET_FILE" GHCR_USERNAME)"
  token="$(env_value "$VPS_SECRET_FILE" GHCR_TOKEN)"
  [[ -n "$username" && -n "$token" ]] || die 'GHCR_USERNAME and GHCR_TOKEN are required for release verification.'
  jq -nc --rawfile username /dev/fd/3 --rawfile token /dev/fd/4 \
    --argjson releases "$services" \
    '{credentials:{username:($username|rtrimstr("\n")),token:($token|rtrimstr("\n"))},releases:$releases}' \
    3<<<"$username" 4<<<"$token" \
    | "$SCRIPT_DIR/scripts/lib/verify-release-provenance.sh"
  unset username token services
}

vps_profile_csv() {
  local profiles=(signal)
  [[ "$(env_value "$VPS_PUBLIC_FILE" ENABLE_BACKUP true)" == true ]] && profiles+=(backup)
  profiles+=(tls)
  [[ "$(env_value "$VPS_PUBLIC_FILE" ENABLE_OFFSITE_BACKUP false)" == true ]] && profiles+=(offsite)
  local IFS=,
  printf '%s' "${profiles[*]}"
}

write_vps_compose_env() {
  local target="$1" release_json="$2"
  {
    printf 'APOLLO_RUNTIME_DIR=/opt/apollo/staged/%s/runtime\n' "$RELEASE_ID"
    printf 'APOLLO_PROGRAM_DIR=/opt/apollo/staged/%s/programs\n' "$RELEASE_ID"
    printf 'NGINX_CONFIG_DIR=/opt/apollo/nginx\nSIGNAL_GEOIP_DIR=/opt/apollo/staged/%s/geoip\nAPOLLO_BIND_IP=0.0.0.0\n' "$RELEASE_ID"
    printf 'POSTGRES_IMAGE=postgres:18.4-bookworm@sha256:882236b897e39051d2368c5ccc6cda944904723506b2dfc97f2a8f5bc9afa382\n'
    printf 'PGBOUNCER_IMAGE=edoburu/pgbouncer:v1.23.1-p2@sha256:122bac472cfb0b92dca81a72421c93c3c5a840899e2002690a39742427cfcd49\n'
    printf 'REDIS_IMAGE=redis:7.4.7-alpine@sha256:02f2cc4882f8bf87c79a220ac958f58c700bdec0dfb9b9ea61b62fb0e8f1bfcf\n'
    printf 'NGINX_IMAGE=nginx:1.27.5-alpine@sha256:65645c7bb6a0661892a8b03b89d0743208a18dd2f3f17a54ef4b76fb8e2f2a10\n'
    printf 'CERTBOT_IMAGE=certbot/certbot:v2.11.0@sha256:ddf9e5d226a56e886986838fa0ebedc0237511c78664352e8d0f4346ee022cd8\n'
    printf 'RESTIC_IMAGE=restic/restic:0.18.1@sha256:39d9072fb5651c80d75c7a811612eb60b4c06b32ffe87c2e9f3c7222e1797e76\n'
    printf 'REDIS_MAX_MEMORY=%s\n' "$(env_value "$VPS_PUBLIC_FILE" REDIS_MAX_MEMORY 256mb)"
    for service in platform signal billing; do
      upper="$(printf '%s' "$service" | tr '[:lower:]' '[:upper:]')"
      printf '%s_IMAGE=%s\n' "$upper" "$(jq -r ".services.$service.image" <<<"$release_json")"
      printf '%s_SOURCE_COMMIT=%s\n' "$upper" "$(jq -r ".services.$service.source_commit" <<<"$release_json")"
    done
  } | write_protected_file "$target"
}

archive_release_tree() {
  local repository="$1" commit="$2" source_path="$3" destination="$4" strip_components="$5"
  local optional="${6:-false}"
  [[ "$commit" =~ ^[0-9a-f]{40}$ ]] || die "Invalid release source commit: $commit"
  [[ -d "$repository/.git" || -f "$repository/.git" ]] || die "Service repository is unavailable: $repository"
  git -C "$repository" cat-file -e "$commit^{commit}" \
    || die "Release source commit is unavailable in $repository: $commit"
  mkdir -p "$destination"
  if ! git -C "$repository" cat-file -e "$commit:$source_path" 2>/dev/null; then
    [[ "$optional" == true ]] && return 0
    die "Required release path is unavailable at $commit: $source_path"
  fi
  git -C "$repository" archive "$commit" "$source_path" \
    | tar -x -C "$destination" --strip-components="$strip_components"
}

stage_vps_release() {
  local release_json="$1" include_nginx="${2:-false}"
  local stage aws_file platform_commit signal_commit billing_commit relative_path
  require_command tar
  stage="$(mktemp -d "${TMPDIR:-/tmp}/apollo-vps-stage.XXXXXX")"
  cleanup_vps_stage() {
    [[ -z "${stage:-}" ]] || rm -rf -- "$stage"
    stage=''
  }
  trap cleanup_vps_stage EXIT INT TERM
  aws_file="$VPS_AWS_FILE"
  require_protected_file "$aws_file" 'Rendered Signal AWS configuration'
  validate_env_file "$aws_file"
  local release_stage="$stage/staged/$RELEASE_ID"
  mkdir -p "$release_stage/programs" "$release_stage/lib" \
    "$release_stage/scripts/lib" "$release_stage/migrations/platform" \
    "$release_stage/migrations/signal" "$release_stage/migrations/billing" \
    "$release_stage/runtime" "$release_stage/config" "$release_stage/geoip"
  cp "$COMPOSE_DIR/compose.yaml" "$release_stage/compose.yaml"
  cp "$PROGRAM_DIR"/*.sh "$release_stage/programs/"
  cp "$SCRIPT_DIR/lib/common.sh" "$release_stage/lib/common.sh"
  cp "$SCRIPT_DIR/scripts/lib/run-migrations.sh" "$SCRIPT_DIR/scripts/lib/apply-signal-grants.sh" \
    "$SCRIPT_DIR/scripts/lib/run-psql-stdin.sh" "$release_stage/scripts/lib/"
  cp "$PROGRAM_DIR/render-oauth-sql.py" "$release_stage/programs/render-oauth-sql.py"
  cp "$SCRIPT_DIR/migration-phases.tsv" "$SCRIPT_DIR/oauth-clients.json" "$release_stage/"
  platform_commit="$(jq -r '.services.platform.source_commit' <<<"$release_json")"
  signal_commit="$(jq -r '.services.signal.source_commit' <<<"$release_json")"
  billing_commit="$(jq -r '.services.billing.source_commit' <<<"$release_json")"
  archive_release_tree "$REPO_ROOT/apollo-platform-api" "$platform_commit" \
    scripts/migrations "$release_stage/migrations/platform" 2
  archive_release_tree "$REPO_ROOT/apollo-signal-api" "$signal_commit" \
    scripts/migrations "$release_stage/migrations/signal" 2
  archive_release_tree "$REPO_ROOT/apollo-billing-api" "$billing_commit" \
    scripts/migrations "$release_stage/migrations/billing" 2
  archive_release_tree "$REPO_ROOT/apollo-signal-api" "$signal_commit" \
    geoip "$release_stage/geoip" 1 true
  cp "$VPS_PUBLIC_FILE" "$release_stage/config/public.env"
  cp "$VPS_SECRET_FILE" "$release_stage/config/secrets.env"
  render_runtime vps "$VPS_PUBLIC_FILE" "$VPS_SECRET_FILE" "$aws_file" "$release_stage/runtime"
  write_vps_compose_env "$release_stage/compose.env" "$release_json"
  if [[ "$include_nginx" == true ]]; then
    archive_release_tree "$REPO_ROOT/apollo-platform-api" "$platform_commit" \
      scripts/nginx "$stage/nginx" 2
    rm -f -- "$stage/nginx/conf.d/10-dev.conf" "$stage/nginx/conf.d/local.conf.example"
    [[ ! -d "$stage/nginx/certs" ]] || find "$stage/nginx/certs" -type f -delete
  fi
  chmod -R go-rwx "$stage/staged"
  VPS_STAGE_IDENTITY="$({
    git -C "$REPO_ROOT" rev-parse HEAD
    while IFS= read -r -d '' staged_file; do
      relative_path="${staged_file#"$stage/"}"
      printf '%s  %s\n' "$(sha256_hex <"$staged_file")" "$relative_path"
    done < <(find "$stage" -type f -print0 | sort -z)
  } | sha256_hex)"
  export VPS_STAGE_IDENTITY
  # shellcheck disable=SC2016 # Dollar expressions in this argument expand only in the remote Bash process.
  tar -C "$stage" -czf - . | vps_ssh bash -c '
    set -euo pipefail
    release_id="$1"
    expected_identity="$2"
    target="/opt/apollo/staged/$release_id"
    exec 9>/opt/apollo/deploy.lock
    flock -w 30 9
    if [[ -f "$target/.apollo-stage-identity" ]] \
      && [[ "$(cat "$target/.apollo-stage-identity")" == "$expected_identity" ]]; then
      cat >/dev/null
      exit 0
    fi
    if [[ -f /opt/apollo/current-release ]] \
      && [[ "$(cat /opt/apollo/current-release)" == "$release_id" ]]; then
      cat >/dev/null
      echo "ERROR: active release ID $release_id cannot be reused with changed staged content" >&2
      exit 1
    fi
    rm -rf -- "$target"
    umask 077
    tar -xzf - -C /opt/apollo
    printf "%s\n" "$expected_identity" >"$target/.apollo-stage-identity.tmp"
    mv "$target/.apollo-stage-identity.tmp" "$target/.apollo-stage-identity"
  ' bash "$RELEASE_ID" "$VPS_STAGE_IDENTITY"
  cleanup_vps_stage
  trap - EXIT INT TERM
}

vps_bootstrap_host() {
  if [[ "$VPS_USER" == root ]]; then
    vps_ssh bash -s -- "$VPS_USER" <"$PROGRAM_DIR/bootstrap-vps.sh"
  else
    vps_ssh sudo -n bash -s -- "$VPS_USER" <"$PROGRAM_DIR/bootstrap-vps.sh"
  fi
}

vps_initialize_storage() {
  vps_ssh bash -s <<'REMOTE'
set -euo pipefail
volumes=(apollo-postgres-data apollo-redis-data apollo-letsencrypt-certs apollo-certbot-webroot apollo-postgres-backups)
established=false
[[ ! -f /opt/apollo/current-release ]] || established=true
docker volume inspect apollo-postgres-data >/dev/null 2>&1 && established=true
for volume in "${volumes[@]}"; do
  if docker volume inspect "$volume" >/dev/null 2>&1; then
    continue
  fi
  if $established; then
    echo "ERROR: established Apollo host is missing durable volume $volume" >&2
    exit 1
  fi
  docker volume create "$volume" >/dev/null
done
docker network inspect apollo >/dev/null 2>&1 || {
  $established && { echo 'ERROR: established Apollo network is missing' >&2; exit 1; }
  docker network create apollo >/dev/null
}
REMOTE
}

vps_deploy_staged() {
  local replace_legacy="${1:-false}" username token deploy_program profiles
  [[ "$replace_legacy" == true || "$replace_legacy" == false ]] || die 'Invalid legacy replacement mode.'
  username="$(env_value "$VPS_SECRET_FILE" GHCR_USERNAME)"
  token="$(env_value "$VPS_SECRET_FILE" GHCR_TOKEN)"
  [[ "$username" =~ ^[A-Za-z0-9][A-Za-z0-9-]{0,38}$ ]] || die 'GHCR_USERNAME is invalid.'
  [[ -n "$token" && "$token" != *$'\n'* && "$token" != *$'\r'* ]] || die 'GHCR_TOKEN is invalid.'
  deploy_program="/opt/apollo/staged/$RELEASE_ID/programs/deploy-remote.sh"
  profiles="$(vps_profile_csv)"
  [[ "${VPS_STAGE_IDENTITY:-}" =~ ^[0-9a-f]{64}$ ]] || die 'Staged release identity is unavailable.'
  # shellcheck disable=SC2016 # Dollar expressions in this argument expand only in the remote Bash process.
  printf '%s\n' "$token" | vps_ssh bash -c '
    set -euo pipefail
    username="$1"
    deploy_program="$2"
    release_id="$3"
    machine_id="$4"
    profiles="$5"
    stage_identity="$6"
    replace_legacy="$7"
    acme_email="$8"
    platform_host="$9"
    signal_host="${10}"
    billing_host="${11}"
    docker_config="$(mktemp -d /opt/apollo/.docker-auth.XXXXXX)"
    cleanup() { rm -rf -- "$docker_config"; }
    trap cleanup EXIT INT TERM
    IFS= read -r token
    printf "%s" "$token" | DOCKER_CONFIG="$docker_config" docker login ghcr.io --username "$username" --password-stdin >/dev/null
    DOCKER_CONFIG="$docker_config" "$deploy_program" \
      "$release_id" "$machine_id" "$profiles" "$stage_identity" \
      "$acme_email" "$platform_host" "$signal_host" "$billing_host" "$replace_legacy"
  ' bash "$username" "$deploy_program" "$RELEASE_ID" "$VPS_EXPECTED_MACHINE_ID" "$profiles" "$VPS_STAGE_IDENTITY" "$replace_legacy" \
    "$(env_value "$VPS_PUBLIC_FILE" LETSENCRYPT_EMAIL)" \
    "$(env_value "$VPS_PUBLIC_FILE" PLATFORM_HOST)" \
    "$(env_value "$VPS_PUBLIC_FILE" SIGNAL_HOST)" \
    "$(env_value "$VPS_PUBLIC_FILE" BILLING_HOST)"
  unset username token
}

vps_setup() {
  ensure_vps_public_config
  assert_trusted_infrastructure
  verify_vps_target
  if [[ ! -f "$VPS_SECRET_FILE" ]] && vps_ssh bash -c \
    'test -f /opt/apollo/current-release || { command -v docker >/dev/null 2>&1 && docker volume inspect apollo-postgres-data >/dev/null 2>&1; }'; then
    die 'Established VPS data exists but vps.secrets.env is missing; recover the exact credentials instead of generating replacements.'
  fi
  ensure_vps_config true
  local release_json
  release_json="$(selected_release_json)"
  verify_selected_release "$release_json"
  terraform_context
  if terraform -chdir="$SCRIPT_DIR/terraform/vps" state list | grep -q '^module[.]deployment'; then
    cleanup_terraform_context
    die 'Terraform-managed VPS containers exist. Run the explicit vps adopt command.'
  fi
  cleanup_terraform_context
  if vps_ssh test -f /opt/apollo/current-release; then
    info 'VPS is already initialized; converging external infrastructure and the selected release.'
    terraform_apply_external true
    write_signal_aws_runtime "$VPS_AWS_FILE"
    stage_vps_release "$release_json" false
    vps_deploy_staged
    vps_status
    return 0
  fi
  terraform_apply_external false
  write_signal_aws_runtime "$VPS_AWS_FILE"
  vps_bootstrap_host
  vps_initialize_storage
  stage_vps_release "$release_json" true
  vps_deploy_staged
  terraform_apply_external true
  write_signal_aws_runtime "$VPS_AWS_FILE"
  vps_status
}

vps_deploy() {
  ensure_vps_config
  assert_trusted_infrastructure
  verify_vps_target
  local release_json
  release_json="$(selected_release_json)"
  verify_selected_release "$release_json"
  stage_vps_release "$release_json" false
  vps_deploy_staged
  vps_status
}

vps_adopt() {
  ensure_vps_config
  assert_trusted_infrastructure
  verify_vps_target
  local release_json
  release_json="$(selected_release_json)"
  verify_selected_release "$release_json"
  confirm_target 'Detach the verified live Docker stack from Terraform and recreate only containers under Compose?'
  terraform_apply_external true
  write_signal_aws_runtime "$VPS_AWS_FILE"
  vps_bootstrap_host
  vps_ssh bash -s <<'REMOTE'
set -euo pipefail
install -d -m 0700 /opt/apollo/nginx
docker cp apollo-platform-nginx:/etc/nginx/. /opt/apollo/nginx/
REMOTE
  vps_initialize_storage
  stage_vps_release "$release_json" false
  vps_deploy_staged true
  vps_status
}

vps_status() {
  ensure_vps_public_config
  verify_vps_target
  vps_ssh bash -s <<'REMOTE'
set -euo pipefail
release=none
[[ ! -f /opt/apollo/current-release ]] || release="$(cat /opt/apollo/current-release)"
printf 'Apollo Deploy\n\nRelease  %s\n\n' "$release"
docker ps --filter 'name=apollo-' --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}'
REMOTE
}

vps_logs() {
  ensure_vps_public_config
  verify_vps_target
  local follow=''
  local service
  for service in "${COMMAND_ARGS[@]}"; do
    [[ "$service" =~ ^[a-z0-9][a-z0-9_-]*$ ]] || die "Invalid Compose service name: $service"
  done
  [[ ${#LOG_FOLLOW[@]} -eq 0 ]] || follow='--follow'
  vps_ssh bash -s -- "$follow" "${COMMAND_ARGS[@]}" <<'REMOTE'
set -euo pipefail
follow="$1"; shift
release="$(cat /opt/apollo/current-release)"
compose=(docker compose --env-file "/opt/apollo/staged/$release/compose.env" -f "/opt/apollo/staged/$release/compose.yaml" --profile signal --profile backup --profile tls)
[[ -z "$follow" ]] || compose+=(--follow)
env -i PATH="$PATH" HOME="${HOME:-/tmp}" DOCKER_CONFIG="${DOCKER_CONFIG:-${HOME:-/tmp}/.docker}" "${compose[@]}" logs "$@"
REMOTE
}

vps_migrate() {
  local phase="$1"
  case "$phase" in expand | contract | all) ;; *) die 'Migration phase must be expand, contract, or all.' ;; esac
  ensure_vps_public_config
  assert_trusted_infrastructure
  verify_vps_target
  vps_ssh bash -s -- "$phase" <<'REMOTE'
set -euo pipefail
phase="$1"
exec 9>/opt/apollo/deploy.lock
flock -w 30 9
release="$(cat /opt/apollo/current-release)"
"/opt/apollo/staged/$release/programs/migrate.sh" "$phase"
REMOTE
}

vps_backup() {
  ensure_vps_public_config
  verify_vps_target
  vps_ssh bash -s <<'REMOTE'
set -euo pipefail
exec 9>/opt/apollo/deploy.lock
flock -w 30 9
before="$(docker exec apollo-postgres-backup cat /backups/.last-success 2>/dev/null || true)"
docker restart apollo-postgres-backup >/dev/null
for _ in {1..120}; do
  after="$(docker exec apollo-postgres-backup cat /backups/.last-success 2>/dev/null || true)"
  [[ -n "$after" && "$after" != "$before" ]] && break
  sleep 2
done
[[ -n "${after:-}" && "$after" != "$before" ]] || {
  echo 'ERROR: PostgreSQL backup did not complete within four minutes.' >&2
  exit 1
}
release="$(cat /opt/apollo/current-release)"
image="$(awk -F= '$1 == "POSTGRES_IMAGE" { print substr($0, index($0, "=") + 1); exit }' "/opt/apollo/staged/$release/compose.env")"
POSTGRES_IMAGE="$image" \
  APOLLO_SECRET_FILE="/opt/apollo/staged/$release/config/secrets.env" \
  "/opt/apollo/staged/$release/programs/restore-check.sh"
REMOTE
  info 'A new PostgreSQL backup completed and restored successfully in isolation.'
}

vps_restore_check() {
  ensure_vps_public_config
  verify_vps_target
  vps_ssh bash -s <<'REMOTE'
set -euo pipefail
release="$(cat /opt/apollo/current-release)"
image="$(awk -F= '$1 == "POSTGRES_IMAGE" { print substr($0, index($0, "=") + 1); exit }' "/opt/apollo/staged/$release/compose.env")"
POSTGRES_IMAGE="$image" \
  APOLLO_SECRET_FILE="/opt/apollo/staged/$release/config/secrets.env" \
  "/opt/apollo/staged/$release/programs/restore-check.sh"
REMOTE
}
