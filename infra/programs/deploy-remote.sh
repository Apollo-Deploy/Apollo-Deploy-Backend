#!/usr/bin/env bash
set -euo pipefail
umask 077

release_id="${1:?release ID is required}"
expected_machine_id="${2:?expected machine ID is required}"
profile_csv="${3:-signal,backup,tls}"
expected_stage_identity="${4:?expected stage identity is required}"
acme_email="${5:?ACME email is required}"
platform_host="${6:?platform host is required}"
signal_host="${7:?signal host is required}"
billing_host="${8:?billing host is required}"
replace_legacy="${9:-false}"
[[ "$release_id" =~ ^[a-z0-9][a-z0-9._-]{0,63}$ ]] || {
  echo 'ERROR: invalid release ID' >&2
  exit 2
}
[[ "$(cat /etc/machine-id)" == "$expected_machine_id" ]] || {
  echo 'ERROR: VPS machine identity mismatch' >&2
  exit 1
}
[[ "$expected_stage_identity" =~ ^[0-9a-f]{64}$ ]] || {
  echo 'ERROR: invalid staged release identity' >&2
  exit 2
}
[[ "$replace_legacy" == true || "$replace_legacy" == false ]] || {
  echo 'ERROR: invalid legacy replacement mode' >&2
  exit 2
}

exec 9>/opt/apollo/deploy.lock
flock -w 30 9 || {
  echo 'ERROR: another Apollo deployment holds the VPS lock' >&2
  exit 1
}

release_root="/opt/apollo/staged/$release_id"
[[ "$(cat "$release_root/.apollo-stage-identity" 2>/dev/null)" == "$expected_stage_identity" ]] || {
  echo 'ERROR: staged release changed before deployment lock acquisition' >&2
  exit 1
}
compose_env="$release_root/compose.env"
[[ -f "$compose_env" && ! -L "$compose_env" ]] || {
  echo 'ERROR: staged release is missing' >&2
  exit 1
}
compose=(docker compose --env-file "$compose_env" -f "$release_root/compose.yaml")
compose_run() {
  env -i PATH="$PATH" HOME="${HOME:-/tmp}" \
    DOCKER_CONFIG="${DOCKER_CONFIG:-${HOME:-/tmp}/.docker}" \
    "${compose[@]}" "$@"
}
IFS=',' read -r -a profile_names <<<"$profile_csv"
for profile in "${profile_names[@]}"; do
  [[ -z "$profile" ]] || compose+=(--profile "$profile")
done

previous_release=''
[[ ! -f /opt/apollo/current-release ]] || previous_release="$(cat /opt/apollo/current-release)"

compose_run pull
APOLLO_SECRET_FILE="$release_root/config/secrets.env" \
  APOLLO_MIGRATION_ROOT="$release_root/migrations" \
  APOLLO_MIGRATION_MANIFEST="$release_root/migration-phases.tsv" \
  APOLLO_OAUTH_DEFINITIONS="$release_root/oauth-clients.json" \
  APOLLO_BASE_DOMAIN="$(awk -F= '$1 == "APOLLO_BASE_DOMAIN" { print substr($0, index($0, "=") + 1); exit }' "$release_root/config/public.env")" \
  "$release_root/programs/migrate.sh" expand

# Repeatable role reconciliation can change PostgreSQL password verifiers while
# an unchanged PgBouncer process still caches the previous auth-query result.
# Restart it before the release health gate so every application connection is
# authenticated against the newly reconciled role credentials.
if docker container inspect apollo-platform-pgbouncer >/dev/null 2>&1; then
  docker restart apollo-platform-pgbouncer >/dev/null
fi

if [[ "$replace_legacy" == true ]]; then
  for container in \
    apollo-postgres-backup-offsite apollo-postgres-backup \
    apollo-platform-certbot apollo-platform-nginx apollo-platform apollo-signal apollo-billing \
    apollo-platform-pgbouncer apollo-platform-redis apollo-platform-postgres; do
    docker container rm --force "$container" >/dev/null 2>&1 || true
  done
fi

release_healthy=true
if ! compose_run up -d --wait; then
  echo "ERROR: release $release_id failed its Compose health gate" >&2
  release_healthy=false
fi

compose_env_value() {
  local key="$1"
  awk -F= -v wanted="$key" '$1 == wanted { print substr($0, index($0, "=") + 1); exit }' "$compose_env"
}

verify_runtime_identity() {
  local service container prefix expected_image expected_commit actual_image actual_commit
  for service in platform signal billing; do
    case "$service" in
      platform)
        container=apollo-platform
        prefix=PLATFORM
        ;;
      signal)
        container=apollo-signal
        prefix=SIGNAL
        ;;
      billing)
        container=apollo-billing
        prefix=BILLING
        ;;
    esac
    expected_image="$(compose_env_value "${prefix}_IMAGE")"
    expected_commit="$(compose_env_value "${prefix}_SOURCE_COMMIT")"
    actual_image="$(docker inspect -f '{{.Config.Image}}' "$container")"
    actual_commit="$(docker inspect -f '{{index .Config.Labels "org.opencontainers.image.revision"}}' "$container")"
    [[ "$actual_image" == "$expected_image" && "$actual_commit" == "$expected_commit" ]] || {
      echo "ERROR: $service runtime identity does not match the approved release" >&2
      return 1
    }
  done
}

if $release_healthy && ! verify_runtime_identity; then
  release_healthy=false
fi

if $release_healthy && [[ ",$profile_csv," == *,backup,* ]]; then
  postgres_image="$(awk -F= '$1 == "POSTGRES_IMAGE" { print substr($0, index($0, "=") + 1); exit }' "$compose_env")"
  if ! POSTGRES_IMAGE="$postgres_image" \
    APOLLO_SECRET_FILE="$release_root/config/secrets.env" \
    "$release_root/programs/restore-check.sh"; then
    echo "ERROR: release $release_id failed isolated backup restore verification" >&2
    release_healthy=false
  fi
fi

public_https_healthy() (
  local platform_url="https://$platform_host/health"
  local signal_url="https://$signal_host/v1/health"
  local billing_url="https://$billing_host/health"
  local headers body
  headers="$(mktemp /tmp/apollo-public-health.XXXXXX)"
  trap 'rm -f -- "$headers"' EXIT INT TERM

  public_probe() {
    local url="$1" service="$2" filter="$3"
    body="$(curl --fail --silent --show-error --noproxy '*' --proto '=https' --tlsv1.2 \
      --connect-timeout 5 --max-time 20 --dump-header "$headers" "$url")" \
      || return 1
    tr -d '\r' <"$headers" | grep -Fqix "x-apollo-service: $service" \
      && jq -e "$filter" <<<"$body" >/dev/null
  }

  for _ in {1..20}; do
    if public_probe "$platform_url" platform '.status == "ok" and .service == "iam"' \
      && public_probe "$signal_url" signal '.status == "ok"' \
      && public_probe "$billing_url" billing '.status == "ok" and .service == "apollo-billing"'; then
      return 0
    fi
    sleep 3
  done
  return 1
)

if $release_healthy; then
  if ! "$release_root/programs/issue-certificates.sh" \
    "$release_id" "$acme_email" "$platform_host" "$signal_host" "$billing_host"; then
    echo "ERROR: release $release_id failed TLS certificate issuance or Nginx reload" >&2
    release_healthy=false
  elif ! public_https_healthy; then
    echo "ERROR: release $release_id failed public HTTPS routing or service identity" >&2
    release_healthy=false
  fi
fi

if ! $release_healthy; then
  if [[ -n "$previous_release" && -f "/opt/apollo/staged/$previous_release/compose.env" ]]; then
    echo "Attempting rollback to $previous_release" >&2
    rollback=(docker compose --env-file "/opt/apollo/staged/$previous_release/compose.env" -f "/opt/apollo/staged/$previous_release/compose.yaml")
    for profile in "${profile_names[@]}"; do
      [[ -z "$profile" ]] || rollback+=(--profile "$profile")
    done
    if env -i PATH="$PATH" HOME="${HOME:-/tmp}" \
      DOCKER_CONFIG="${DOCKER_CONFIG:-${HOME:-/tmp}/.docker}" \
      "${rollback[@]}" up -d --wait; then
      printf '%s\n' "$previous_release" >/opt/apollo/.current-release.tmp
      mv /opt/apollo/.current-release.tmp /opt/apollo/current-release
    else
      echo 'ERROR: automatic rollback also failed' >&2
      rm -f -- /opt/apollo/current-release
    fi
  else
    compose_run stop || echo 'ERROR: failed candidate could not be stopped' >&2
    rm -f -- /opt/apollo/current-release
  fi
  exit 1
fi

printf '%s\n' "$release_id" >/opt/apollo/.current-release.tmp
mv /opt/apollo/.current-release.tmp /opt/apollo/current-release
for staged_path in /opt/apollo/staged/*; do
  [[ -e "$staged_path" || -L "$staged_path" ]] || continue
  staged_name="${staged_path##*/}"
  [[ "$staged_name" == "$release_id" || "$staged_name" == "$previous_release" ]] && continue
  rm -rf -- "$staged_path"
done
printf 'Release %s is healthy.\n' "$release_id"
