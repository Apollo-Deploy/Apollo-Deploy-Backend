#!/usr/bin/env bash

local_tls_is_current() {
  local tls_dir="$REPO_ROOT/apollo-platform-api/scripts/nginx/certs"
  local certificate="$tls_dir/apollo-local.pem"
  local private_key="$tls_dir/apollo-local-key.pem"
  local ca_root hostname certificate_key private_key_value certificate_text
  [[ -r "$certificate" && -r "$private_key" ]] || return 1
  ca_root="$(mkcert -CAROOT)/rootCA.pem"
  [[ -r "$ca_root" ]] || return 1
  openssl x509 -in "$certificate" -noout -checkend 86400 >/dev/null 2>&1 || return 1
  openssl verify -CAfile "$ca_root" "$certificate" >/dev/null 2>&1 || return 1
  certificate_key="$(openssl x509 -in "$certificate" -pubkey -noout 2>/dev/null | openssl pkey -pubin -outform pem 2>/dev/null)" || return 1
  private_key_value="$(openssl pkey -in "$private_key" -pubout -outform pem 2>/dev/null)" || return 1
  [[ "$certificate_key" == "$private_key_value" ]] || return 1
  certificate_text="$(openssl x509 -in "$certificate" -noout -text 2>/dev/null)" || return 1
  for hostname in apollodeploy.local '*.apollodeploy.local' \
    api.platform.apollodeploy.local api.signal.apollodeploy.local \
    api.billing.apollodeploy.local; do
    [[ "$certificate_text" == *"DNS:$hostname"* ]] || return 1
  done
}

ensure_local_tls() {
  local tls_dir="$REPO_ROOT/apollo-platform-api/scripts/nginx/certs"
  require_command mkcert
  require_command openssl
  mkcert -install >/dev/null 2>&1 || die 'Could not install the local mkcert CA.'
  if local_tls_is_current; then
    info 'Local HTTPS certificate is current.'
    return 0
  fi
  mkdir -p "$tls_dir"
  mkcert -cert-file "$tls_dir/apollo-local.pem" \
    -key-file "$tls_dir/apollo-local-key.pem" \
    apollodeploy.local '*.apollodeploy.local' \
    api.platform.apollodeploy.local api.signal.apollodeploy.local \
    api.billing.apollodeploy.local
  chmod 600 "$tls_dir/apollo-local-key.pem"
  chmod 644 "$tls_dir/apollo-local.pem"
  local_tls_is_current || die 'Generated local TLS certificate did not pass validation.'
}

render_local_runtime() {
  ensure_local_config
  render_runtime local "$CONFIG_DIR/local.env" "$CONFIG_DIR/local.secrets.env" '' "$RUNTIME_ROOT/local"
  write_local_compose_env
}

local_setup() {
  require_command docker
  require_command jq
  require_command openssl
  require_command python3
  docker info >/dev/null 2>&1 || die 'Docker daemon is unavailable.'
  if docker container inspect apollo-platform-postgres >/dev/null 2>&1 \
    && [[ "$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' apollo-platform-postgres 2>/dev/null)" != apollo ]]; then
    die 'Legacy Terraform-managed local containers were detected; use the pre-cleanup migration procedure before running this checkout.'
  fi
  ensure_local_tls
  render_local_runtime
  ensure_local_docker_resources
  info 'Starting PostgreSQL, PgBouncer, and Redis...'
  compose_local up -d --wait postgres pgbouncer redis
  local_migrate expand
  info 'Starting Apollo services...'
  compose_local up -d --wait
  local_status
}

local_migrate() {
  local phase="${1:-expand}"
  render_local_runtime
  APOLLO_SECRET_FILE="$CONFIG_DIR/local.secrets.env" \
    APOLLO_MIGRATION_ROOT="$REPO_ROOT" \
    APOLLO_MIGRATION_MANIFEST="$SCRIPT_DIR/migration-phases.tsv" \
    APOLLO_OAUTH_DEFINITIONS="$SCRIPT_DIR/oauth-clients.json" \
    APOLLO_BASE_DOMAIN="$(env_value "$CONFIG_DIR/local.env" APOLLO_BASE_DOMAIN)" \
    "$PROGRAM_DIR/migrate.sh" "$phase"
}

local_status() {
  render_local_runtime
  compose_local ps
  printf '\nURLs\n  Platform  https://%s\n  Signal    https://%s\n  Billing   https://%s\n' \
    "$(env_value "$CONFIG_DIR/local.env" PLATFORM_HOST)" \
    "$(env_value "$CONFIG_DIR/local.env" SIGNAL_HOST)" \
    "$(env_value "$CONFIG_DIR/local.env" BILLING_HOST)"
}

local_logs() {
  render_local_runtime
  compose_local logs "${LOG_FOLLOW[@]}" "${COMMAND_ARGS[@]}"
}

local_up() {
  ensure_local_tls
  render_local_runtime
  ensure_local_docker_resources
  compose_local up -d --wait
  local_status
}

local_down() {
  render_local_runtime
  compose_local stop
}
