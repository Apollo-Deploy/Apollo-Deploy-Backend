#!/usr/bin/env bash
set -euo pipefail

operator_user="${1:?operator user is required}"
[[ "$operator_user" =~ ^[A-Za-z_][A-Za-z0-9_-]*$ ]] \
  || {
    echo 'ERROR: invalid operator user' >&2
    exit 2
  }
[[ "$(id -u)" -eq 0 ]] || {
  echo 'ERROR: bootstrap must run as root' >&2
  exit 1
}

# shellcheck disable=SC1091 # This standard host file is available only on the target Linux VPS.
. /etc/os-release
[[ "${ID:-}" == ubuntu || "${ID:-}" == debian ]] \
  || {
    echo 'ERROR: Apollo VPS bootstrap supports Debian/Ubuntu only.' >&2
    exit 1
  }
apt-get update
apt-get install -y ca-certificates curl jq openssl python3 util-linux

if ! command -v docker >/dev/null 2>&1 || ! docker compose version >/dev/null 2>&1; then
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL "https://download.docker.com/linux/$ID/gpg" -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  architecture="$(dpkg --print-architecture)"
  codename="${VERSION_CODENAME:?missing VERSION_CODENAME}"
  printf 'Types: deb\nURIs: https://download.docker.com/linux/%s\nSuites: %s\nComponents: stable\nArchitectures: %s\nSigned-By: /etc/apt/keyrings/docker.asc\n' \
    "$ID" "$codename" "$architecture" >/etc/apt/sources.list.d/docker.sources
  apt-get update
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
fi

install -d -m 0711 /opt/apollo /opt/apollo/staged
install -d -m 0755 /opt/apollo/nginx

if [[ "$operator_user" != root ]]; then
  id "$operator_user" >/dev/null 2>&1 || {
    echo 'ERROR: operator user does not exist' >&2
    exit 1
  }
  usermod -aG docker "$operator_user"
  chown -R "$operator_user:$operator_user" /opt/apollo
fi

docker info >/dev/null
docker compose version >/dev/null
