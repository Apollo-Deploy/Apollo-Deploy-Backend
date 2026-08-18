#!/usr/bin/env bash

compose_profiles() {
  local public_file="$1"
  local profiles=()
  [[ "$(env_value "$public_file" ENABLE_SIGNAL true)" == true ]] && profiles+=(--profile signal)
  [[ "$(env_value "$public_file" ENABLE_BACKUP false)" == true ]] && profiles+=(--profile backup)
  [[ "$(env_value "$public_file" ENABLE_OFFSITE_BACKUP false)" == true ]] && profiles+=(--profile offsite)
  [[ "${2:-}" == vps ]] && profiles+=(--profile tls)
  printf '%s\n' "${profiles[@]}"
}

compose_local() {
  local runtime_dir="$RUNTIME_ROOT/local"
  local public_file="$CONFIG_DIR/local.env"
  local -a profiles=()
  while IFS= read -r profile; do
    [[ -n "$profile" ]] && profiles+=("$profile")
  done < <(compose_profiles "$public_file" local)
  docker compose \
    --env-file "$runtime_dir/compose.env" \
    -f "$COMPOSE_DIR/compose.yaml" \
    -f "$COMPOSE_DIR/compose.local.yaml" \
    "${profiles[@]}" "$@"
}

write_local_compose_env() {
  local runtime_dir="$RUNTIME_ROOT/local"
  local public_file="$CONFIG_DIR/local.env"
  local npmrc_path="$REPO_ROOT/apollo-platform-api/.npmrc"
  [[ -f "$npmrc_path" ]] || npmrc_path="$HOME/.npmrc"
  [[ -f "$npmrc_path" ]] || die 'Platform local development requires a readable .npmrc.'

  {
    printf 'REPO_ROOT=%s\n' "$REPO_ROOT"
    printf 'APOLLO_RUNTIME_DIR=%s\n' "$runtime_dir"
    printf 'APOLLO_PROGRAM_DIR=%s\n' "$PROGRAM_DIR"
    printf 'NGINX_CONFIG_DIR=%s\n' "$REPO_ROOT/apollo-platform-api/scripts/nginx"
    printf 'SIGNAL_GEOIP_DIR=%s\n' "$REPO_ROOT/apollo-signal-api/geoip"
    printf 'NPMRC_PATH=%s\n' "$npmrc_path"
    printf 'APOLLO_BIND_IP=127.0.0.1\n'
    printf 'POSTGRES_IMAGE=postgres:18.4-bookworm@sha256:882236b897e39051d2368c5ccc6cda944904723506b2dfc97f2a8f5bc9afa382\n'
    printf 'PGBOUNCER_IMAGE=edoburu/pgbouncer:v1.23.1-p2@sha256:122bac472cfb0b92dca81a72421c93c3c5a840899e2002690a39742427cfcd49\n'
    printf 'REDIS_IMAGE=redis:7.4.7-alpine@sha256:02f2cc4882f8bf87c79a220ac958f58c700bdec0dfb9b9ea61b62fb0e8f1bfcf\n'
    printf 'NGINX_IMAGE=nginx:1.27.5-alpine@sha256:65645c7bb6a0661892a8b03b89d0743208a18dd2f3f17a54ef4b76fb8e2f2a10\n'
    printf 'CERTBOT_IMAGE=certbot/certbot:v2.11.0@sha256:ddf9e5d226a56e886986838fa0ebedc0237511c78664352e8d0f4346ee022cd8\n'
    printf 'RESTIC_IMAGE=restic/restic:0.18.1@sha256:39d9072fb5651c80d75c7a811612eb60b4c06b32ffe87c2e9f3c7222e1797e76\n'
    printf 'PLATFORM_IMAGE=oven/bun:1.3.11-alpine\nSIGNAL_IMAGE=eclipse-temurin:21-jdk-alpine\nBILLING_IMAGE=eclipse-temurin:21-jdk-alpine\n'
    printf 'REDIS_MAX_MEMORY=%s\n' "$(env_value "$public_file" REDIS_MAX_MEMORY 256mb)"
  } | write_protected_file "$runtime_dir/compose.env"
}

ensure_local_docker_resources() {
  local resource existing=false
  local resources=(apollo-postgres-data apollo-redis-data apollo-letsencrypt-certs
    apollo-certbot-webroot apollo-signal-gradle-cache apollo-billing-gradle-cache)
  [[ "$(env_value "$CONFIG_DIR/local.env" ENABLE_BACKUP false)" != true ]] \
    || resources+=(apollo-postgres-backups)
  for resource in "${resources[@]}"; do
    if docker volume inspect "$resource" >/dev/null 2>&1; then
      existing=true
      continue
    fi
    if docker container inspect apollo-platform-postgres >/dev/null 2>&1; then
      die "Established local stack is missing volume $resource; restore it explicitly before running setup."
    fi
    docker volume create "$resource" >/dev/null
  done
  if ! docker network inspect apollo >/dev/null 2>&1; then
    $existing && die 'Established local volumes exist but the Apollo network is missing; recreate the apollo network explicitly before setup.'
    docker network create apollo >/dev/null
  fi
}
