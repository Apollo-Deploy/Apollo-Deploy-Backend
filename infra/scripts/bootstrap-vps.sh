#!/usr/bin/env bash
# =============================================================================
# bootstrap-vps.sh — Prepares a fresh VPS for Apollo Deploy
#
# What it does:
#   1. Configures a default-deny firewall and the pre-Docker origin gate
#   2. Installs Docker Engine (if not already present) behind that gate
#   3. Creates the /opt/apollo directory structure
#   4. Syncs nginx configuration
#
# Usage:
#   bash infra/scripts/bootstrap-vps.sh user@1.2.3.4
#   bash infra/scripts/bootstrap-vps.sh -p 2222 -i ~/.ssh/apollo deploy@my-vps.example.com
#   bash infra/scripts/bootstrap-vps.sh -d deploy@my-vps.example.com
#
# After bootstrap:
#   1. Configure the canonical infra/terraform/vps root
#   2. Initialize its encrypted, locked remote state backend before planning
# =============================================================================

set -euo pipefail

# ── Args ──────────────────────────────────────────────────────────────────────
SSH_PORT=22
SSH_KEY_PATH=""
HTTPS_ACCESS_MODE="cloudflare"

usage() {
  echo "Usage: $0 [-p ssh_port] [-i ssh_key] [-d] user@host" >&2
}

while getopts "p:i:d" opt; do
  case $opt in
    p) SSH_PORT="$OPTARG" ;;
    i) SSH_KEY_PATH="$OPTARG" ;;
    d) HTTPS_ACCESS_MODE="direct" ;;
    *) usage; exit 1 ;;
  esac
done
shift $((OPTIND - 1))

if ! [[ "$SSH_PORT" =~ ^[0-9]+$ ]] || ((SSH_PORT < 1 || SSH_PORT > 65535)); then
  echo "ERROR: SSH port must be an integer between 1 and 65535." >&2
  exit 1
fi

if [ "$#" -ne 1 ]; then
  usage
  exit 1
fi

REMOTE="$1"
if ! [[ "$REMOTE" =~ ^[a-z_][a-z0-9_-]*@([A-Za-z0-9][A-Za-z0-9.-]*|\[[0-9A-Fa-f:]+\])$ ]]; then
  echo "ERROR: target must be user@hostname, user@IPv4, or user@[IPv6]." >&2
  exit 1
fi

if [[ "$SSH_KEY_PATH" == \~/* ]]; then
  SSH_KEY_PATH="$HOME/${SSH_KEY_PATH#\~/}"
fi
if [ -n "$SSH_KEY_PATH" ] && [ ! -r "$SSH_KEY_PATH" ]; then
  echo "ERROR: SSH private key is not readable: $SSH_KEY_PATH" >&2
  exit 1
fi

SSH=(ssh -p "$SSH_PORT" -o StrictHostKeyChecking=yes)
if [ -n "$SSH_KEY_PATH" ]; then
  SSH+=(-i "$SSH_KEY_PATH")
fi

# Resolve and validate every local input before the first remote mutation.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
NGINX_SRC="${REPO_ROOT}/apollo-platform-api/scripts/nginx"

required_nginx_files=(
  nginx.conf
  conf.d/00-default.conf
  conf.d/api-redirect.conf
  snippets/acme-challenge.conf
  snippets/locations-billing.conf
  snippets/locations-platform.conf
  snippets/locations-signal.conf
  snippets/proxy.conf
  snippets/security-headers.conf
  snippets/ssl-params.conf
)
for required_file in "${required_nginx_files[@]}"; do
  if [ ! -f "$NGINX_SRC/$required_file" ] || [ ! -r "$NGINX_SRC/$required_file" ]; then
    echo "ERROR: Required nginx source is not readable: $NGINX_SRC/$required_file" >&2
    echo "       Initialize the service submodules before bootstrapping the VPS." >&2
    exit 1
  fi
done

required_local_commands=(ssh rsync base64)
if [ "$HTTPS_ACCESS_MODE" = "cloudflare" ]; then
  required_local_commands+=(curl)
fi
for required_command in "${required_local_commands[@]}"; do
  if ! command -v "$required_command" >/dev/null 2>&1; then
    echo "ERROR: Required local command is unavailable: $required_command" >&2
    exit 1
  fi
done

CLOUDFLARE_IPV4_B64=""
CLOUDFLARE_IPV6_B64=""
NGINX_REMOTE_STAGE_B64=""

valid_ipv4_cidr() {
  local cidr="$1" ip prefix extra a b c d octet

  IFS=/ read -r ip prefix extra <<EOF
$cidr
EOF
  [ -z "${extra:-}" ] && [[ "${prefix:-}" =~ ^[0-9]{1,2}$ ]] \
    && ((10#$prefix <= 32)) || return 1
  IFS=. read -r a b c d <<EOF
$ip
EOF
  for octet in "${a:-}" "${b:-}" "${c:-}" "${d:-}"; do
    [[ "$octet" =~ ^[0-9]{1,3}$ ]] && ((10#$octet <= 255)) || return 1
  done
}

valid_ipv6_cidr() {
  local cidr="$1" address prefix extra

  IFS=/ read -r address prefix extra <<EOF
$cidr
EOF
  [ -z "${extra:-}" ] \
    && [[ "${address:-}" =~ ^[0-9A-Fa-f:]+$ ]] \
    && [[ "$address" == *:* ]] \
    && [[ "${prefix:-}" =~ ^[0-9]{1,3}$ ]] \
    && ((10#$prefix <= 128))
}

fetch_cloudflare_ranges() {
  local ipv4_response ipv6_response range
  local ipv4_ranges=()
  local ipv6_ranges=()

  echo "==> Fetching Cloudflare's authoritative proxy ranges..."
  ipv4_response="$(curl --fail --silent --show-error --location \
    --proto '=https' --tlsv1.2 https://www.cloudflare.com/ips-v4)" \
    || {
      echo "ERROR: Could not obtain Cloudflare IPv4 ranges; no remote changes were made." >&2
      exit 1
    }
  ipv6_response="$(curl --fail --silent --show-error --location \
    --proto '=https' --tlsv1.2 https://www.cloudflare.com/ips-v6)" \
    || {
      echo "ERROR: Could not obtain Cloudflare IPv6 ranges; no remote changes were made." >&2
      exit 1
    }

  while IFS= read -r range || [ -n "$range" ]; do
    range="${range%$'\r'}"
    [ -n "$range" ] || continue
    if ! valid_ipv4_cidr "$range"; then
      echo "ERROR: Cloudflare returned an invalid IPv4 range: $range" >&2
      exit 1
    fi
    ipv4_ranges+=("$range")
  done <<<"$ipv4_response"

  while IFS= read -r range || [ -n "$range" ]; do
    range="${range%$'\r'}"
    [ -n "$range" ] || continue
    if ! valid_ipv6_cidr "$range"; then
      echo "ERROR: Cloudflare returned an invalid IPv6 range: $range" >&2
      exit 1
    fi
    ipv6_ranges+=("$range")
  done <<<"$ipv6_response"

  if [ "${#ipv4_ranges[@]}" -eq 0 ] || [ "${#ipv6_ranges[@]}" -eq 0 ]; then
    echo "ERROR: Cloudflare returned an empty proxy range list; no remote changes were made." >&2
    exit 1
  fi

  CLOUDFLARE_IPV4_B64="$(printf '%s\n' "${ipv4_ranges[@]}" | base64 | tr -d '\n')"
  CLOUDFLARE_IPV6_B64="$(printf '%s\n' "${ipv6_ranges[@]}" | base64 | tr -d '\n')"
}

if [ "$HTTPS_ACCESS_MODE" = "cloudflare" ]; then
  fetch_cloudflare_ranges
else
  echo "WARNING: Direct-origin HTTPS is enabled; port 443 will accept traffic from any address." >&2
fi

remote_root_bash() {
  # Variables in this command are deliberately expanded by the remote shell.
  # shellcheck disable=SC2016
  "${SSH[@]}" "$REMOTE" \
    "APOLLO_BOOTSTRAP_SSH_PORT=$SSH_PORT" \
    "APOLLO_HTTPS_ACCESS_MODE=$HTTPS_ACCESS_MODE" \
    "APOLLO_CLOUDFLARE_IPV4_B64=$CLOUDFLARE_IPV4_B64" \
    "APOLLO_CLOUDFLARE_IPV6_B64=$CLOUDFLARE_IPV6_B64" \
    "APOLLO_NGINX_REMOTE_STAGE_B64=$NGINX_REMOTE_STAGE_B64" '
    apollo_ssh_user=$(id -un)
    if [ "$(id -u)" -eq 0 ]; then
      export APOLLO_SSH_USER="$apollo_ssh_user" APOLLO_BOOTSTRAP_SSH_PORT
      export APOLLO_HTTPS_ACCESS_MODE APOLLO_CLOUDFLARE_IPV4_B64
      export APOLLO_CLOUDFLARE_IPV6_B64 APOLLO_NGINX_REMOTE_STAGE_B64
      exec bash -s
    fi
    if command -v sudo >/dev/null 2>&1 && sudo -n true; then
      exec sudo -n env \
        APOLLO_SSH_USER="$apollo_ssh_user" \
        APOLLO_BOOTSTRAP_SSH_PORT="$APOLLO_BOOTSTRAP_SSH_PORT" \
        APOLLO_HTTPS_ACCESS_MODE="$APOLLO_HTTPS_ACCESS_MODE" \
        APOLLO_CLOUDFLARE_IPV4_B64="$APOLLO_CLOUDFLARE_IPV4_B64" \
        APOLLO_CLOUDFLARE_IPV6_B64="$APOLLO_CLOUDFLARE_IPV6_B64" \
        APOLLO_NGINX_REMOTE_STAGE_B64="$APOLLO_NGINX_REMOTE_STAGE_B64" \
        bash -s
    fi
    echo "ERROR: VPS bootstrap requires root or passwordless sudo." >&2
    exit 1
  '
}

echo "==> Bootstrapping VPS: ${REMOTE} (port ${SSH_PORT})"

# ── 1. Firewall and pre-Docker origin gate ────────────────────────────────────
echo "==> Configuring host firewall..."
remote_root_bash <<'FIREWALL_REMOTE'
set -euo pipefail
ssh_port="$APOLLO_BOOTSTRAP_SSH_PORT"
https_access_mode="$APOLLO_HTTPS_ACCESS_MODE"
firewall_state_dir=/etc/apollo
ipv4_state_file="$firewall_state_dir/cloudflare-ips-v4"
ipv6_state_file="$firewall_state_dir/cloudflare-ips-v6"
https_mode_file="$firewall_state_dir/https-access-mode"
cloudflare_ipv4=""
cloudflare_ipv6=""

decode_ranges() {
  local encoded="$1"
  [ -n "$encoded" ] || return 0
  printf '%s' "$encoded" | base64 --decode
}

valid_ipv4_cidr() {
  local cidr="$1" ip prefix extra a b c d octet
  IFS=/ read -r ip prefix extra <<<"$cidr"
  [ -z "${extra:-}" ] && [[ "${prefix:-}" =~ ^[0-9]{1,2}$ ]] \
    && ((10#$prefix <= 32)) || return 1
  IFS=. read -r a b c d <<<"$ip"
  for octet in "${a:-}" "${b:-}" "${c:-}" "${d:-}"; do
    [[ "$octet" =~ ^[0-9]{1,3}$ ]] && ((10#$octet <= 255)) || return 1
  done
}

valid_ipv6_cidr() {
  local cidr="$1" address prefix extra
  IFS=/ read -r address prefix extra <<<"$cidr"
  [ -z "${extra:-}" ] \
    && [[ "${address:-}" =~ ^[0-9A-Fa-f:]+$ ]] \
    && [[ "$address" == *:* ]] \
    && [[ "${prefix:-}" =~ ^[0-9]{1,3}$ ]] \
    && ((10#$prefix <= 128))
}

validate_range_list() {
  local family="$1" ranges="$2" range count=0
  while IFS= read -r range || [ -n "$range" ]; do
    [ -n "$range" ] || continue
    if [ "$family" = ipv4 ]; then
      valid_ipv4_cidr "$range" || return 1
    else
      valid_ipv6_cidr "$range" || return 1
    fi
    count=$((count + 1))
  done <<<"$ranges"
  [ "$count" -gt 0 ]
}

range_is_current() {
  local expected="$1" ranges="$2" candidate
  while IFS= read -r candidate || [ -n "$candidate" ]; do
    [ "$candidate" = "$expected" ] && return 0
  done <<<"$ranges"
  return 1
}

if [ -e "$firewall_state_dir" ] \
  && { [ ! -d "$firewall_state_dir" ] || [ -L "$firewall_state_dir" ]; }; then
  echo "ERROR: Refusing unsafe firewall state directory: $firewall_state_dir" >&2
  exit 1
fi
for stored_file in "$ipv4_state_file" "$ipv6_state_file" "$https_mode_file"; do
  if [ -e "$stored_file" ] && { [ ! -f "$stored_file" ] || [ -L "$stored_file" ]; }; then
    echo "ERROR: Refusing unsafe firewall state path: $stored_file" >&2
    exit 1
  fi
done

case "$https_access_mode" in
  cloudflare)
    cloudflare_ipv4="$(decode_ranges "$APOLLO_CLOUDFLARE_IPV4_B64")"
    cloudflare_ipv6="$(decode_ranges "$APOLLO_CLOUDFLARE_IPV6_B64")"
    if ! validate_range_list ipv4 "$cloudflare_ipv4" \
      || ! validate_range_list ipv6 "$cloudflare_ipv6"; then
      echo "ERROR: Refusing invalid Cloudflare firewall ranges." >&2
      exit 1
    fi
    ;;
  direct) ;;
  *)
    echo "ERROR: Unsupported HTTPS access mode: $https_access_mode" >&2
    exit 1
    ;;
esac

. /etc/os-release
case "${ID}" in
  ubuntu|debian)
    apt-get update -qq
    apt-get install -y -qq python3 ufw
    ufw default deny incoming
    ufw default allow outgoing
    ufw allow "${ssh_port}/tcp"
    ufw allow 80/tcp

    previous_ipv4="$([ -r "$ipv4_state_file" ] && cat "$ipv4_state_file" || true)"
    previous_ipv6="$([ -r "$ipv6_state_file" ] && cat "$ipv6_state_file" || true)"
    if [ "$https_access_mode" = cloudflare ]; then
      # Add current rules before removing broad or stale access so a refresh
      # cannot interrupt proxied traffic.
      while IFS= read -r range || [ -n "$range" ]; do
        [ -n "$range" ] || continue
        ufw allow proto tcp from "$range" to any port 443 comment 'Apollo Cloudflare HTTPS'
      done <<<"$cloudflare_ipv4"
      while IFS= read -r range || [ -n "$range" ]; do
        [ -n "$range" ] || continue
        ufw allow proto tcp from "$range" to any port 443 comment 'Apollo Cloudflare HTTPS'
      done <<<"$cloudflare_ipv6"

      while IFS= read -r range || [ -n "$range" ]; do
        [ -n "$range" ] || continue
        if valid_ipv4_cidr "$range" && ! range_is_current "$range" "$cloudflare_ipv4"; then
          ufw --force delete allow proto tcp from "$range" to any port 443 >/dev/null 2>&1 || true
        fi
      done <<<"$previous_ipv4"
      while IFS= read -r range || [ -n "$range" ]; do
        [ -n "$range" ] || continue
        if valid_ipv6_cidr "$range" && ! range_is_current "$range" "$cloudflare_ipv6"; then
          ufw --force delete allow proto tcp from "$range" to any port 443 >/dev/null 2>&1 || true
        fi
      done <<<"$previous_ipv6"

      # This is the world-access rule installed by older bootstrap versions.
      ufw --force delete allow 443/tcp >/dev/null 2>&1 || true
    else
      ufw allow 443/tcp comment 'Apollo direct HTTPS'
      while IFS= read -r range || [ -n "$range" ]; do
        [ -n "$range" ] || continue
        valid_ipv4_cidr "$range" \
          && ufw --force delete allow proto tcp from "$range" to any port 443 >/dev/null 2>&1 || true
      done <<<"$previous_ipv4"
      while IFS= read -r range || [ -n "$range" ]; do
        [ -n "$range" ] || continue
        valid_ipv6_cidr "$range" \
          && ufw --force delete allow proto tcp from "$range" to any port 443 >/dev/null 2>&1 || true
      done <<<"$previous_ipv6"
    fi
    ufw --force enable
    ;;
  centos|rhel|fedora|almalinux|rocky)
    dnf install -y -q firewalld python3
    systemctl enable --now firewalld
    firewall-cmd --permanent --add-port="${ssh_port}/tcp"
    firewall-cmd --permanent --add-service=http

    previous_ipv4="$([ -r "$ipv4_state_file" ] && cat "$ipv4_state_file" || true)"
    previous_ipv6="$([ -r "$ipv6_state_file" ] && cat "$ipv6_state_file" || true)"
    if [ "$https_access_mode" = cloudflare ]; then
      while IFS= read -r range || [ -n "$range" ]; do
        [ -n "$range" ] || continue
        rule="rule family=\"ipv4\" source address=\"$range\" port port=\"443\" protocol=\"tcp\" accept"
        firewall-cmd --permanent --add-rich-rule="$rule"
      done <<<"$cloudflare_ipv4"
      while IFS= read -r range || [ -n "$range" ]; do
        [ -n "$range" ] || continue
        rule="rule family=\"ipv6\" source address=\"$range\" port port=\"443\" protocol=\"tcp\" accept"
        firewall-cmd --permanent --add-rich-rule="$rule"
      done <<<"$cloudflare_ipv6"

      while IFS= read -r range || [ -n "$range" ]; do
        [ -n "$range" ] || continue
        if valid_ipv4_cidr "$range" && ! range_is_current "$range" "$cloudflare_ipv4"; then
          rule="rule family=\"ipv4\" source address=\"$range\" port port=\"443\" protocol=\"tcp\" accept"
          firewall-cmd --permanent --remove-rich-rule="$rule" >/dev/null 2>&1 || true
        fi
      done <<<"$previous_ipv4"
      while IFS= read -r range || [ -n "$range" ]; do
        [ -n "$range" ] || continue
        if valid_ipv6_cidr "$range" && ! range_is_current "$range" "$cloudflare_ipv6"; then
          rule="rule family=\"ipv6\" source address=\"$range\" port port=\"443\" protocol=\"tcp\" accept"
          firewall-cmd --permanent --remove-rich-rule="$rule" >/dev/null 2>&1 || true
        fi
      done <<<"$previous_ipv6"

      firewall-cmd --permanent --remove-service=https >/dev/null 2>&1 || true
      firewall-cmd --permanent --remove-port=443/tcp >/dev/null 2>&1 || true
    else
      firewall-cmd --permanent --add-service=https
      while IFS= read -r range || [ -n "$range" ]; do
        [ -n "$range" ] || continue
        if valid_ipv4_cidr "$range"; then
          rule="rule family=\"ipv4\" source address=\"$range\" port port=\"443\" protocol=\"tcp\" accept"
          firewall-cmd --permanent --remove-rich-rule="$rule" >/dev/null 2>&1 || true
        fi
      done <<<"$previous_ipv4"
      while IFS= read -r range || [ -n "$range" ]; do
        [ -n "$range" ] || continue
        if valid_ipv6_cidr "$range"; then
          rule="rule family=\"ipv6\" source address=\"$range\" port port=\"443\" protocol=\"tcp\" accept"
          firewall-cmd --permanent --remove-rich-rule="$rule" >/dev/null 2>&1 || true
        fi
      done <<<"$previous_ipv6"
    fi
    firewall-cmd --reload
    ;;
  *)
    echo "Unsupported OS for automatic firewall configuration: ${ID}" >&2
    exit 1
    ;;
esac

install -d -m 0755 "$firewall_state_dir"
ipv4_tmp="$(mktemp "$firewall_state_dir/.cloudflare-ips-v4.XXXXXX")"
ipv6_tmp="$(mktemp "$firewall_state_dir/.cloudflare-ips-v6.XXXXXX")"
https_mode_tmp="$(mktemp "$firewall_state_dir/.https-access-mode.XXXXXX")"
if [ "$https_access_mode" = cloudflare ]; then
  printf '%s\n' "$cloudflare_ipv4" >"$ipv4_tmp"
  printf '%s\n' "$cloudflare_ipv6" >"$ipv6_tmp"
else
  : >"$ipv4_tmp"
  : >"$ipv6_tmp"
fi
printf '%s\n' "$https_access_mode" >"$https_mode_tmp"
chmod 0644 "$ipv4_tmp" "$ipv6_tmp" "$https_mode_tmp"
mv -f -- "$ipv4_tmp" "$ipv4_state_file"
mv -f -- "$ipv6_tmp" "$ipv6_state_file"
mv -f -- "$https_mode_tmp" "$https_mode_file"

# Docker publishes nginx through its forwarding/NAT path, which bypasses host
# INPUT rules on common UFW and firewalld configurations. Persist an independent
# DOCKER-USER policy so the Cloudflare-only default is actually enforced.
docker_firewall_tmp="$(mktemp)"
docker_backend_validator_tmp="$(mktemp)"
docker_firewall_unit_tmp="$(mktemp)"
docker_firewall_dropin_tmp="$(mktemp)"
docker_nginx_start_tmp="$(mktemp)"
docker_nginx_unit_tmp="$(mktemp)"
cleanup_firewall_install() {
  rm -f -- \
    "$docker_firewall_tmp" \
    "$docker_backend_validator_tmp" \
    "$docker_firewall_unit_tmp" \
    "$docker_firewall_dropin_tmp" \
    "$docker_nginx_start_tmp" \
    "$docker_nginx_unit_tmp"
}
trap cleanup_firewall_install EXIT

cat >"$docker_backend_validator_tmp" <<'DOCKER_BACKEND_VALIDATOR'
#!/usr/bin/env bash
set -Eeuo pipefail

state_dir=/etc/apollo
mode_file="$state_dir/https-access-mode"
daemon_config=/etc/docker/daemon.json

die() {
  echo "ERROR: $*" >&2
  exit 1
}

[ -f "$mode_file" ] && [ ! -L "$mode_file" ] && [ -r "$mode_file" ] \
  || die "Unsafe or unreadable HTTPS access-mode file: $mode_file"
https_mode="$(<"$mode_file")"
case "$https_mode" in
  direct) exit 0 ;;
  cloudflare) ;;
  *) die "Unsupported persisted HTTPS access mode: $https_mode" ;;
esac

command -v python3 >/dev/null 2>&1 \
  || die "python3 is required to validate Docker's firewall backend"

if [ -e "$daemon_config" ]; then
  [ -f "$daemon_config" ] && [ ! -L "$daemon_config" ] \
    && [ -r "$daemon_config" ] \
    || die "Unsafe or unreadable Docker daemon configuration: $daemon_config"
  python3 - "$daemon_config" <<'PYTHON_VALIDATE_DOCKER_CONFIG'
import json
import sys

path = sys.argv[1]
try:
    with open(path, encoding="utf-8") as config_file:
        config = json.load(config_file)
except (OSError, ValueError) as error:
    print(f"ERROR: Cannot validate Docker daemon configuration {path}: {error}", file=sys.stderr)
    raise SystemExit(1)

if not isinstance(config, dict):
    print(f"ERROR: Docker daemon configuration must be a JSON object: {path}", file=sys.stderr)
    raise SystemExit(1)

backend = config.get("firewall-backend", "iptables")
iptables_enabled = config.get("iptables", True)
if backend != "iptables" or iptables_enabled is not True:
    print(
        "ERROR: Cloudflare-only HTTPS requires Docker's iptables firewall backend "
        "with iptables enabled.",
        file=sys.stderr,
    )
    raise SystemExit(1)
PYTHON_VALIDATE_DOCKER_CONFIG
fi

# The default unit and /etc/docker/daemon.json are the only accepted sources of
# firewall-backend configuration. Reject deferred or command-line overrides:
# they cannot be resolved safely while a brownfield daemon is stopped.
if docker_exec_start="$(systemctl show --property=ExecStart --value docker.service 2>/dev/null)"; then
  case "$docker_exec_start" in
    *'$'*|*--config-file*|*--firewall-backend*|*--iptables*)
      die "Docker's ExecStart contains an unsupported deferred or firewall override; use the validated $daemon_config instead"
      ;;
  esac
  case "$docker_exec_start" in
    '{ path=/usr/bin/dockerd ; argv[]=/usr/bin/dockerd '* \
      |'{ path=/usr/sbin/dockerd ; argv[]=/usr/sbin/dockerd '*) ;;
    *)
      die "Docker's resolved ExecStart is not the allowlisted packaged dockerd binary"
      ;;
  esac
elif command -v docker >/dev/null 2>&1; then
  die "Docker is installed but its systemd ExecStart cannot be inspected"
fi
DOCKER_BACKEND_VALIDATOR

cat >"$docker_firewall_tmp" <<'DOCKER_FIREWALL'
#!/usr/bin/env bash
set -Eeuo pipefail

state_dir=/etc/apollo
mode_file="$state_dir/https-access-mode"
ipv4_file="$state_dir/cloudflare-ips-v4"
ipv6_file="$state_dir/cloudflare-ips-v6"
guard_comment='Apollo HTTPS fail-closed guard'
bridge_outputs=(docker0 'br+')
firewall_action=apply

if [ "$#" -eq 1 ] && [ "$1" = --guard ]; then
  firewall_action=guard
elif [ "$#" -ne 0 ]; then
  echo "Usage: $0 [--guard]" >&2
  exit 1
fi

ensure_guard_rules() {
  local tool="$1" output

  for output in "${bridge_outputs[@]}"; do
    if ! "$tool" -w 5 -C DOCKER-USER -o "$output" \
      -p tcp --dport 443 -m comment --comment "$guard_comment" -j DROP \
      >/dev/null 2>&1; then
      "$tool" -w 5 -I DOCKER-USER 1 -o "$output" \
        -p tcp --dport 443 -m comment --comment "$guard_comment" -j DROP
    fi
  done
}

guards_are_installed() {
  local tool="$1" output

  for output in "${bridge_outputs[@]}"; do
    "$tool" -w 5 -C DOCKER-USER -o "$output" \
      -p tcp --dport 443 -m comment --comment "$guard_comment" -j DROP \
      >/dev/null 2>&1 || return 1
  done
}

emergency_close_https() {
  local guard_installed=false

  if command -v iptables >/dev/null 2>&1; then
    if ! iptables -w 5 -n -L DOCKER-USER >/dev/null 2>&1; then
      iptables -w 5 -N DOCKER-USER >/dev/null 2>&1 || true
    fi
    if iptables -w 5 -n -L DOCKER-USER >/dev/null 2>&1; then
      ensure_guard_rules iptables >/dev/null 2>&1 || true
      if guards_are_installed iptables; then
        # Before dockerd starts, the guard is effective as soon as Docker adds
        # its documented FORWARD jump. During a live apply, however, an
        # unreferenced DOCKER-USER chain provides no protection, so stop nginx
        # unless that jump is already present.
        if [ "$firewall_action" = guard ] \
          || iptables -w 5 -C FORWARD -j DOCKER-USER >/dev/null 2>&1; then
          guard_installed=true
        fi
      fi
    fi
  fi

  if [ "$guard_installed" = false ] \
    && command -v docker >/dev/null 2>&1 \
    && docker container inspect apollo-platform-nginx >/dev/null 2>&1; then
    docker stop apollo-platform-nginx >/dev/null 2>&1 || true
    echo "ERROR: Stopped apollo-platform-nginx because forwarded HTTPS could not be closed safely." >&2
  fi
}

die() {
  echo "ERROR: $*" >&2
  if [ "${https_mode:-cloudflare}" != direct ]; then
    emergency_close_https
  fi
  exit 1
}

on_error() {
  local exit_status=$?
  trap - ERR
  if [ "${https_mode:-cloudflare}" != direct ]; then
    emergency_close_https
  fi
  exit "$exit_status"
}
trap on_error ERR

valid_ipv4_cidr() {
  local cidr="$1" ip prefix extra a b c d octet
  IFS=/ read -r ip prefix extra <<<"$cidr"
  [ -z "${extra:-}" ] && [[ "${prefix:-}" =~ ^[0-9]{1,2}$ ]] \
    && ((10#$prefix <= 32)) || return 1
  IFS=. read -r a b c d <<<"$ip"
  for octet in "${a:-}" "${b:-}" "${c:-}" "${d:-}"; do
    [[ "$octet" =~ ^[0-9]{1,3}$ ]] && ((10#$octet <= 255)) || return 1
  done
}

valid_ipv6_cidr() {
  local cidr="$1" address prefix extra
  IFS=/ read -r address prefix extra <<<"$cidr"
  [ -z "${extra:-}" ] \
    && [[ "${address:-}" =~ ^[0-9A-Fa-f:]+$ ]] \
    && [[ "$address" == *:* ]] \
    && [[ "${prefix:-}" =~ ^[0-9]{1,3}$ ]] \
    && ((10#$prefix <= 128))
}

validate_range_file() {
  local family="$1" range_file="$2" range count=0
  [ -f "$range_file" ] && [ ! -L "$range_file" ] && [ -r "$range_file" ] \
    || die "Unsafe or unreadable Cloudflare range file: $range_file"
  while IFS= read -r range || [ -n "$range" ]; do
    [ -n "$range" ] || continue
    if [ "$family" = ipv4 ]; then
      valid_ipv4_cidr "$range" || die "Invalid IPv4 range in $range_file: $range"
    else
      valid_ipv6_cidr "$range" || die "Invalid IPv6 range in $range_file: $range"
    fi
    count=$((count + 1))
  done <"$range_file"
  [ "$count" -gt 0 ] || die "Cloudflare range file is empty: $range_file"
}

managed_jump_targets() {
  local tool="$1" prefix="$2"
  "$tool" -w 5 -S DOCKER-USER | awk -v prefix="$prefix" '
    $1 == "-A" && $2 == "DOCKER-USER" {
      for (i = 3; i < NF; i++) {
        if ($i == "-j" && $(i + 1) ~ ("^" prefix "[0-9]+$")) {
          print $(i + 1)
        }
      }
    }
  ' | sort -u
}

managed_chains() {
  local tool="$1" prefix="$2"
  "$tool" -w 5 -S | awk -v prefix="$prefix" '
    $1 == "-N" && $2 ~ ("^" prefix "[0-9]+$") { print $2 }
  ' | sort -u
}

remove_guard() {
  local tool="$1" output

  for output in "${bridge_outputs[@]}"; do
    while "$tool" -w 5 -C DOCKER-USER -o "$output" \
      -p tcp --dport 443 -m comment --comment "$guard_comment" -j DROP \
      >/dev/null 2>&1; do
      "$tool" -w 5 -D DOCKER-USER -o "$output" \
        -p tcp --dport 443 -m comment --comment "$guard_comment" -j DROP
    done
  done

  remove_retired_unscoped_guard "$tool"
}

remove_retired_unscoped_guard() {
  local tool="$1"

  # The retired directionless guard blocked outbound HTTPS from Docker bridges
  # as well as inbound traffic. Callers first install scoped protection.
  while "$tool" -w 5 -C DOCKER-USER \
    -p tcp --dport 443 -m comment --comment "$guard_comment" -j DROP \
    >/dev/null 2>&1; do
    "$tool" -w 5 -D DOCKER-USER \
      -p tcp --dport 443 -m comment --comment "$guard_comment" -j DROP
  done
}

remove_chain_jumps() {
  local tool="$1" chain="$2" output

  for output in "${bridge_outputs[@]}"; do
    while "$tool" -w 5 -C DOCKER-USER -o "$output" \
      -p tcp --dport 443 -j "$chain" >/dev/null 2>&1; do
      "$tool" -w 5 -D DOCKER-USER -o "$output" \
        -p tcp --dport 443 -j "$chain"
    done
  done

  # Also recognize and remove the retired, directionless jump shape.
  while "$tool" -w 5 -C DOCKER-USER -p tcp --dport 443 -j "$chain" \
    >/dev/null 2>&1; do
    "$tool" -w 5 -D DOCKER-USER -p tcp --dport 443 -j "$chain"
  done
}

has_scoped_managed_jump() {
  local tool="$1" prefix="$2" output="$3" chain

  while IFS= read -r chain; do
    [ -n "$chain" ] || continue
    if "$tool" -w 5 -C DOCKER-USER -o "$output" \
      -p tcp --dport 443 -j "$chain" >/dev/null 2>&1; then
      return 0
    fi
  done < <(managed_jump_targets "$tool" "$prefix")
  return 1
}

remove_legacy_managed_jumps() {
  local tool="$1" prefix="$2" chain

  while IFS= read -r chain; do
    [ -n "$chain" ] || continue
    while "$tool" -w 5 -C DOCKER-USER -p tcp --dport 443 -j "$chain" \
      >/dev/null 2>&1; do
      "$tool" -w 5 -D DOCKER-USER -p tcp --dport 443 -j "$chain"
    done
  done < <(managed_jump_targets "$tool" "$prefix")
}

remove_managed_policy() {
  local tool="$1" prefix="$2" keep_chain="${3:-}" chain

  while IFS= read -r chain; do
    [ -n "$chain" ] && [ "$chain" != "$keep_chain" ] || continue
    remove_chain_jumps "$tool" "$chain"
  done < <(managed_jump_targets "$tool" "$prefix")

  while IFS= read -r chain; do
    [ -n "$chain" ] && [ "$chain" != "$keep_chain" ] || continue
    remove_chain_jumps "$tool" "$chain"
    "$tool" -w 5 -F "$chain"
    "$tool" -w 5 -X "$chain"
  done < <(managed_chains "$tool" "$prefix")
}

remove_orphan_chains() {
  local tool="$1" prefix="$2" chain
  while IFS= read -r chain; do
    [ -n "$chain" ] || continue
    "$tool" -w 5 -F "$chain"
    "$tool" -w 5 -X "$chain"
  done < <(managed_chains "$tool" "$prefix")
}

install_prestart_guard() {
  local tool="$1" family="$2" prefix="$3"

  if ! command -v "$tool" >/dev/null 2>&1; then
    [ "$family" = ipv6 ] \
      && { echo "Docker IPv6 forwarding tools are unavailable; Terraform publishes nginx on IPv4 0.0.0.0."; return 0; }
    die "$tool is required before Docker can start safely"
  fi

  if [ "$https_mode" = direct ]; then
    if "$tool" -w 5 -n -L DOCKER-USER >/dev/null 2>&1; then
      remove_managed_policy "$tool" "$prefix"
      remove_guard "$tool"
    else
      remove_orphan_chains "$tool" "$prefix"
    fi
    return 0
  fi

  if ! "$tool" -w 5 -n -L DOCKER-USER >/dev/null 2>&1; then
    "$tool" -w 5 -N DOCKER-USER
  fi
  ensure_guard_rules "$tool"
  remove_managed_policy "$tool" "$prefix"

  # Docker documents DOCKER-USER as preserving user rules across daemon
  # operations. Remove only the retired unscoped guard after both inbound-only
  # guards exist, so container egress is never blocked by this transition.
  remove_retired_unscoped_guard "$tool"
  guards_are_installed "$tool" \
    || die "Could not install the $family pre-Docker HTTPS guard"
}

configure_family() {
  local tool="$1" family="$2" range_file="$3" prefix="$4"
  local range new_chain output attempt=0

  if ! command -v "$tool" >/dev/null 2>&1; then
    [ "$family" = ipv6 ] \
      && { echo "Docker IPv6 forwarding is unavailable; nginx is published on Terraform's IPv4 0.0.0.0 binding."; return 0; }
    die "$tool is required to enforce Docker-published HTTPS policy"
  fi
  if ! "$tool" -w 5 -n -L DOCKER-USER >/dev/null 2>&1; then
    if [ "$https_mode" = direct ]; then
      remove_orphan_chains "$tool" "$prefix"
      return 0
    fi
    [ "$family" = ipv6 ] \
      && { echo "Docker has no IPv6 DOCKER-USER chain; nginx is published on Terraform's IPv4 0.0.0.0 binding."; return 0; }
    die "Docker's IPv4 DOCKER-USER chain is unavailable; refusing an unenforced origin policy"
  fi

  if [ "$https_mode" = direct ]; then
    remove_managed_policy "$tool" "$prefix"
    remove_guard "$tool"
    return 0
  fi

  if ! "$tool" -w 5 -C FORWARD -j DOCKER-USER >/dev/null 2>&1; then
    if [ "$family" = ipv6 ]; then
      remove_managed_policy "$tool" "$prefix"
      remove_guard "$tool"
      echo "Docker has no IPv6 FORWARD jump to DOCKER-USER; Terraform publishes nginx on IPv4 0.0.0.0."
      return 0
    fi
    die "Docker's IPv4 FORWARD jump to DOCKER-USER is unavailable; refusing an unenforced origin policy"
  fi

  for output in "${bridge_outputs[@]}"; do
    if ! has_scoped_managed_jump "$tool" "$prefix" "$output" \
      && ! "$tool" -w 5 -C DOCKER-USER -o "$output" \
        -p tcp --dport 443 -m comment --comment "$guard_comment" -j DROP \
        >/dev/null 2>&1; then
      # Leave this interface-scoped guard in place if validation or policy
      # construction fails. Container-originated HTTPS uses an external output
      # interface and therefore never enters this guard.
      "$tool" -w 5 -I DOCKER-USER 1 -o "$output" \
        -p tcp --dport 443 -m comment --comment "$guard_comment" -j DROP
    fi
  done
  remove_legacy_managed_jumps "$tool" "$prefix"
  remove_retired_unscoped_guard "$tool"

  validate_range_file "$family" "$range_file"
  while :; do
    new_chain="${prefix}${RANDOM}${RANDOM}"
    if ! "$tool" -w 5 -S "$new_chain" >/dev/null 2>&1; then
      break
    fi
    attempt=$((attempt + 1))
    [ "$attempt" -lt 20 ] || die "Could not allocate a managed Docker firewall chain"
  done

  "$tool" -w 5 -N "$new_chain"
  "$tool" -w 5 -A "$new_chain" \
    -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN
  while IFS= read -r range || [ -n "$range" ]; do
    [ -n "$range" ] || continue
    "$tool" -w 5 -A "$new_chain" -p tcp -s "$range" --dport 443 -j RETURN
  done <"$range_file"
  "$tool" -w 5 -A "$new_chain" -p tcp --dport 443 -j DROP
  "$tool" -w 5 -A "$new_chain" -j RETURN

  # Switch to the fully-built generation before deleting older generations.
  # If cleanup fails, the newest chain remains first and fail-closed.
  for output in "${bridge_outputs[@]}"; do
    "$tool" -w 5 -I DOCKER-USER 1 -o "$output" \
      -p tcp --dport 443 -j "$new_chain"
  done
  remove_managed_policy "$tool" "$prefix" "$new_chain"
  remove_guard "$tool"

  for output in "${bridge_outputs[@]}"; do
    "$tool" -w 5 -C DOCKER-USER -o "$output" \
      -p tcp --dport 443 -j "$new_chain" >/dev/null 2>&1 \
      || die "The managed $family policy is missing its $output inbound jump"
  done
}

for required_command in awk sort; do
  command -v "$required_command" >/dev/null 2>&1 \
    || die "Required command is unavailable: $required_command"
done
[ -f "$mode_file" ] && [ ! -L "$mode_file" ] && [ -r "$mode_file" ] \
  || die "Unsafe or unreadable HTTPS access-mode file: $mode_file"
https_mode="$(<"$mode_file")"
case "$https_mode" in
  cloudflare|direct) ;;
  *) die "Unsupported persisted HTTPS access mode: $https_mode" ;;
esac

case "$firewall_action" in
  guard)
    install_prestart_guard iptables ipv4 APOLLO-H4-
    install_prestart_guard ip6tables ipv6 APOLLO-H6-
    echo "Pre-Docker HTTPS guard applied in $https_mode mode."
    ;;
  apply)
    configure_family iptables ipv4 "$ipv4_file" APOLLO-H4-
    # Terraform deliberately publishes nginx on 0.0.0.0. If Docker IPv6
    # forwarding is enabled, apply the same policy; otherwise report the
    # omission explicitly instead of claiming IPv6 enforcement.
    configure_family ip6tables ipv6 "$ipv6_file" APOLLO-H6-
    echo "Docker-published HTTPS policy applied in $https_mode mode."
    ;;
esac
DOCKER_FIREWALL

cat >"$docker_nginx_start_tmp" <<'DOCKER_NGINX_START'
#!/usr/bin/env bash
set -Eeuo pipefail

nginx_container=apollo-platform-nginx
if ! docker container inspect "$nginx_container" >/dev/null 2>&1; then
  echo "ERROR: $nginx_container is not deployed yet; keeping its protected start gate retrying." >&2
  exit 1
fi

restart_policy="$(docker inspect --format='{{.HostConfig.RestartPolicy.Name}}' "$nginx_container")"
if [ "$restart_policy" != on-failure ]; then
  echo "ERROR: Refusing to start $nginx_container with restart policy '$restart_policy'." >&2
  echo "       Run bootstrap-vps.sh to converge the protected lifecycle first." >&2
  exit 1
fi

if [ "$(docker inspect --format='{{.State.Running}}' "$nginx_container")" != true ]; then
  docker start "$nginx_container" >/dev/null
fi

# Docker only activates a restart policy after a container has remained up for
# ten seconds. Keep this oneshot failed (and therefore retrying) until the
# protected generation crosses that boundary, even if it was already running
# when this helper was invoked.
stable_seconds=0
while [ "$stable_seconds" -lt 10 ]; do
  sleep 1
  if [ "$(docker inspect --format='{{.State.Running}}' "$nginx_container")" != true ]; then
    echo "ERROR: $nginx_container exited before its Docker restart policy became active." >&2
    exit 1
  fi
  stable_seconds=$((stable_seconds + 1))
done
DOCKER_NGINX_START

cat >"$docker_firewall_unit_tmp" <<'DOCKER_FIREWALL_UNIT'
[Unit]
Description=Apollo Docker-published HTTPS firewall
Requires=docker.service
PartOf=docker.service
Wants=network-online.target
After=docker.service network-online.target ufw.service firewalld.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/apollo-docker-firewall
RemainAfterExit=yes

[Install]
WantedBy=docker.service
DOCKER_FIREWALL_UNIT

cat >"$docker_nginx_unit_tmp" <<'DOCKER_NGINX_UNIT'
[Unit]
Description=Start Apollo nginx after Docker origin policy
Requires=docker.service apollo-docker-firewall.service
After=docker.service apollo-docker-firewall.service
PartOf=docker.service
StartLimitIntervalSec=0

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/apollo-start-platform-nginx
RemainAfterExit=yes
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=docker.service
DOCKER_NGINX_UNIT

cat >"$docker_firewall_dropin_tmp" <<'DOCKER_FIREWALL_DROPIN'
[Unit]
# If the distribution firewall participates in this boot transaction, let it
# restore/reload first; a missing unit adds no dependency and is harmless.
After=ufw.service firewalld.service

[Service]
# Before every daemon start, create DOCKER-USER with inbound-only DROP guards.
# First reject daemon backends that do not implement this iptables contract.
# Moby then preserves user rules in DOCKER-USER and adds its FORWARD jump. The
# post-start apply replaces the guards only after the reviewed allowlist exists.
ExecStartPre=/usr/local/sbin/apollo-validate-docker-firewall-backend
ExecStartPre=/usr/local/sbin/apollo-docker-firewall --guard
ExecStartPost=/usr/local/sbin/apollo-docker-firewall
DOCKER_FIREWALL_DROPIN

bash -n "$docker_backend_validator_tmp"
bash -n "$docker_firewall_tmp"
bash -n "$docker_nginx_start_tmp"
install -o root -g root -m 0755 "$docker_backend_validator_tmp" \
  /usr/local/sbin/apollo-validate-docker-firewall-backend
install -o root -g root -m 0755 "$docker_firewall_tmp" \
  /usr/local/sbin/apollo-docker-firewall
install -o root -g root -m 0755 "$docker_nginx_start_tmp" \
  /usr/local/sbin/apollo-start-platform-nginx
install -o root -g root -m 0644 "$docker_firewall_unit_tmp" \
  /etc/systemd/system/apollo-docker-firewall.service
install -o root -g root -m 0644 "$docker_nginx_unit_tmp" \
  /etc/systemd/system/apollo-start-platform-nginx.service
if [ -e /etc/systemd/system/docker.service.d ] \
  && { [ ! -d /etc/systemd/system/docker.service.d ] \
    || [ -L /etc/systemd/system/docker.service.d ]; }; then
  echo "ERROR: Refusing unsafe Docker systemd drop-in directory." >&2
  exit 1
fi
install -d -o root -g root -m 0755 /etc/systemd/system/docker.service.d
install -o root -g root -m 0644 "$docker_firewall_dropin_tmp" \
  /etc/systemd/system/docker.service.d/10-apollo-firewall.conf
for installed_file in \
  /usr/local/sbin/apollo-validate-docker-firewall-backend \
  /usr/local/sbin/apollo-docker-firewall \
  /usr/local/sbin/apollo-start-platform-nginx \
  /etc/systemd/system/apollo-docker-firewall.service \
  /etc/systemd/system/apollo-start-platform-nginx.service \
  /etc/systemd/system/docker.service.d/10-apollo-firewall.conf; do
  [ -f "$installed_file" ] && [ ! -L "$installed_file" ] \
    && [ "$(stat -c '%u:%g' "$installed_file")" = '0:0' ] \
    || { echo "ERROR: Docker firewall installation is not root-owned: $installed_file" >&2; exit 1; }
done
systemctl daemon-reload
systemctl reenable \
  apollo-docker-firewall.service \
  apollo-start-platform-nginx.service

/usr/local/sbin/apollo-validate-docker-firewall-backend

if systemctl is-active --quiet docker.service; then
  # Brownfield running daemons need the policy immediately. A stopped daemon is
  # left stopped; its drop-in will run the same guard before its next start.
  systemctl restart apollo-docker-firewall.service
  systemctl is-active --quiet apollo-docker-firewall.service
else
  /usr/local/sbin/apollo-docker-firewall --guard
fi

trap - EXIT
cleanup_firewall_install
FIREWALL_REMOTE

# ── 2. Install and start Docker behind the origin gate ────────────────────────────────────
echo "==> Installing Docker Engine behind the fail-closed gate..."
remote_root_bash <<'DOCKER_INSTALL_REMOTE'
set -euo pipefail
docker_runtime_masked=false

remove_docker_runtime_mask() {
  if [ "$docker_runtime_masked" = true ]; then
    systemctl unmask --runtime docker.service docker.socket >/dev/null 2>&1 || true
    docker_runtime_masked=false
    systemctl daemon-reload
  fi
}
trap remove_docker_runtime_mask EXIT

if command -v docker >/dev/null 2>&1; then
  echo "Docker already installed: $(docker --version)"
else
  if [ ! -f /etc/os-release ]; then
    echo "Cannot detect OS — install Docker manually then re-run." >&2
    exit 1
  fi
  . /etc/os-release
  OS_ID="${ID}"

  # Package post-install hooks commonly start Docker. A runtime mask prevents
  # that first start until the previously installed drop-in is ready to run.
  systemctl mask --runtime docker.service docker.socket
  docker_runtime_masked=true

  case "${OS_ID}" in
    ubuntu|debian)
      apt-get update -qq
      apt-get install -y -qq ca-certificates curl gnupg
      install -m 0755 -d /etc/apt/keyrings
      curl -fsSL "https://download.docker.com/linux/${OS_ID}/gpg" \
        | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
      chmod a+r /etc/apt/keyrings/docker.gpg
      echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
        https://download.docker.com/linux/${OS_ID} $(. /etc/os-release && echo ${VERSION_CODENAME}) stable" \
        | tee /etc/apt/sources.list.d/docker.list >/dev/null
      apt-get update -qq
      apt-get install -y -qq \
        docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
      ;;
    centos|rhel|fedora|almalinux|rocky)
      dnf install -y -q dnf-plugins-core
      dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
      dnf install -y -q \
        docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
      ;;
    *)
      echo "Unsupported OS: ${OS_ID}. Install Docker manually." >&2
      exit 1
      ;;
  esac

  remove_docker_runtime_mask
fi

# This is the first intentional daemon activation. The unprefixed pre/post
# hooks fail the unit if either the guard or complete policy cannot be applied.
/usr/local/sbin/apollo-validate-docker-firewall-backend
systemctl enable --now docker.service
if ! docker info >/dev/null 2>&1; then
  echo "ERROR: Docker is installed but its daemon is unavailable." >&2
  exit 1
fi
# Wait for the enabled post-Docker policy unit even if systemd scheduled the
# wanted unit concurrently with the Docker start transaction.
systemctl start apollo-docker-firewall.service
systemctl is-active --quiet apollo-docker-firewall.service

if [ "$APOLLO_HTTPS_ACCESS_MODE" = cloudflare ]; then
  live_restore_enabled="$(docker info --format '{{.LiveRestoreEnabled}}')" || {
    echo "ERROR: Could not determine Docker live-restore status." >&2
    exit 1
  }
  if [ "$live_restore_enabled" != false ]; then
    echo "ERROR: Cloudflare-only HTTPS requires Docker live-restore to be disabled." >&2
    echo "       Live-restored containers can outlive the daemon policy/start gate." >&2
    exit 1
  fi
fi

if docker container inspect apollo-platform-nginx >/dev/null 2>&1; then
  # The origin policy is active before this in-place lifecycle convergence.
  docker update --restart on-failure apollo-platform-nginx >/dev/null
  [ "$(docker inspect --format='{{.HostConfig.RestartPolicy.Name}}' apollo-platform-nginx)" = on-failure ] \
    || { echo "ERROR: Could not converge the nginx restart policy." >&2; exit 1; }
fi

# A failed helper execution is retried persistently by this dedicated unit. An
# absent container is expected on first bootstrap, so arm the retry without
# blocking the later Terraform deployment. If nginx already exists, wait
# through a bounded initial failure for a successful systemd retry.
nginx_container_present=false
if docker container inspect apollo-platform-nginx >/dev/null 2>&1; then
  nginx_container_present=true
fi
if ! systemctl restart apollo-start-platform-nginx.service; then
  echo "nginx start gate is retrying until a protected nginx generation is healthy." >&2
fi
if [ "$nginx_container_present" = true ]; then
  nginx_start_waits=0
  until systemctl is-active --quiet apollo-start-platform-nginx.service; do
    nginx_start_waits=$((nginx_start_waits + 1))
    if [ "$nginx_start_waits" -ge 12 ]; then
      echo "ERROR: nginx did not recover through its protected systemd start gate." >&2
      exit 1
    fi
    sleep 5
  done
else
  systemctl is-enabled --quiet apollo-start-platform-nginx.service
  echo "nginx is not deployed yet; its persistent protected start retry is armed."
fi

if [ "$APOLLO_SSH_USER" != root ]; then
  usermod -aG docker "$APOLLO_SSH_USER"
fi

trap - EXIT
remove_docker_runtime_mask
echo "Docker ready: $(docker --version)"
DOCKER_INSTALL_REMOTE

# rsync must exist on both ends. This is separate from Docker installation so
# an already-provisioned Docker host is still repaired when rsync is missing.
echo "==> Ensuring rsync is installed..."
remote_root_bash <<'ENDSSH'
set -euo pipefail
if command -v rsync >/dev/null 2>&1; then
  exit 0
fi

. /etc/os-release
case "${ID}" in
  ubuntu|debian)
    apt-get update -qq
    apt-get install -y -qq rsync
    ;;
  centos|rhel|fedora|almalinux|rocky)
    dnf install -y -q rsync
    ;;
  *)
    echo "Unsupported OS for automatic rsync installation: ${ID}" >&2
    exit 1
    ;;
esac
ENDSSH

# ── 3. Create directory structure ─────────────────────────────────────────────
echo "==> Creating /opt/apollo directory structure..."
remote_root_bash <<'ENDSSH'
set -euo pipefail
mkdir -p \
  /opt/apollo/platform/nginx \
  /opt/apollo/signal/geoip \
  /opt/apollo/src

chmod 755 /opt/apollo
if [ "$APOLLO_SSH_USER" != "root" ]; then
  # Keep any root-owned rollback snapshots under /opt/apollo protected.
  chown "$APOLLO_SSH_USER:$APOLLO_SSH_USER" \
    /opt/apollo \
    /opt/apollo/platform \
    /opt/apollo/platform/nginx \
    /opt/apollo/signal \
    /opt/apollo/signal/geoip \
    /opt/apollo/src
fi
echo "Directory structure ready."
ENDSSH

# ── 4. Sync nginx config ──────────────────────────────────────────────────────
echo "==> Syncing nginx config to VPS..."
# Expanded deliberately by the remote shell.
# shellcheck disable=SC2016
REMOTE_NGINX_STAGE="$("${SSH[@]}" "$REMOTE" '
  set -eu
  umask 077
  stage=$(mktemp -d /opt/apollo/nginx-stage.XXXXXX)
  mkdir -m 0700 "$stage/source"
  printf "%s\n" "$stage"
')"
if [[ ! "$REMOTE_NGINX_STAGE" =~ ^/opt/apollo/nginx-stage\.[A-Za-z0-9]+$ ]]; then
  echo "ERROR: Refusing unexpected remote nginx staging path: $REMOTE_NGINX_STAGE" >&2
  exit 1
fi

cleanup_remote_nginx_stage() {
  local exit_status=$?
  trap - EXIT
  "${SSH[@]}" "$REMOTE" "rm -rf -- '$REMOTE_NGINX_STAGE'" >/dev/null 2>&1 || true
  exit "$exit_status"
}
trap cleanup_remote_nginx_stage EXIT

printf -v RSYNC_SHELL 'ssh -p %q -o StrictHostKeyChecking=yes' "$SSH_PORT"
if [ -n "$SSH_KEY_PATH" ]; then
  printf -v RSYNC_SHELL '%s -i %q' "$RSYNC_SHELL" "$SSH_KEY_PATH"
fi
rsync -az -e "$RSYNC_SHELL" \
  --exclude '/certs/' \
  --exclude '/local/' \
  --exclude '/conf.d/10-dev.conf' \
  --exclude '/conf.d/20-production.conf' \
  --exclude '/conf.d/local.conf.example' \
  "${NGINX_SRC}/" "${REMOTE}:${REMOTE_NGINX_STAGE}/source/"

NGINX_REMOTE_STAGE_B64="$(printf '%s' "$REMOTE_NGINX_STAGE" | base64 | tr -d '\n')"
remote_root_bash <<'NGINX_SYNC_REMOTE'
set -euo pipefail
nginx_root=/opt/apollo/platform/nginx
nginx_container=apollo-platform-nginx
backup_parent=/var/lib/apollo
stage_root="$(printf '%s' "$APOLLO_NGINX_REMOTE_STAGE_B64" | base64 --decode)"
https_access_mode="$APOLLO_HTTPS_ACCESS_MODE"
cloudflare_ipv4=""
cloudflare_ipv6=""

if [[ ! "$stage_root" =~ ^/opt/apollo/nginx-stage\.[A-Za-z0-9]+$ ]] \
  || [ ! -d "$stage_root" ] || [ -L "$stage_root" ]; then
  echo "ERROR: Refusing unsafe nginx staging directory: $stage_root" >&2
  exit 1
fi
stage_source="$stage_root/source"
if [ ! -d "$stage_source" ] || [ -L "$stage_source" ]; then
  echo "ERROR: Staged nginx source is unavailable." >&2
  exit 1
fi
if find "$stage_source" -type l -print -quit | grep -q .; then
  echo "ERROR: Staged nginx source must not contain symbolic links." >&2
  exit 1
fi

required_files=(
  nginx.conf
  conf.d/00-default.conf
  conf.d/api-redirect.conf
  snippets/acme-challenge.conf
  snippets/locations-billing.conf
  snippets/locations-platform.conf
  snippets/locations-signal.conf
  snippets/proxy.conf
  snippets/security-headers.conf
  snippets/ssl-params.conf
)
for required_file in "${required_files[@]}"; do
  if [ ! -f "$stage_source/$required_file" ] || [ ! -r "$stage_source/$required_file" ]; then
    echo "ERROR: Staged nginx source is incomplete: $required_file" >&2
    exit 1
  fi
done

case "$https_access_mode" in
  cloudflare)
    cloudflare_ipv4="$(printf '%s' "$APOLLO_CLOUDFLARE_IPV4_B64" | base64 --decode)"
    cloudflare_ipv6="$(printf '%s' "$APOLLO_CLOUDFLARE_IPV6_B64" | base64 --decode)"
    [ -n "$cloudflare_ipv4" ] && [ -n "$cloudflare_ipv6" ] || {
      echo "ERROR: Cloudflare real-IP ranges are unavailable." >&2
      exit 1
    }
    ;;
  direct) ;;
  *)
    echo "ERROR: Unsupported HTTPS access mode: $https_access_mode" >&2
    exit 1
    ;;
esac

if [ -e "$backup_parent" ] \
  && { [ ! -d "$backup_parent" ] || [ -L "$backup_parent" ]; }; then
  echo "ERROR: Refusing unsafe nginx backup parent: $backup_parent" >&2
  exit 1
fi
install -d -o root -g root -m 0700 "$backup_parent"
backup_dir="$(umask 077 && mktemp -d "$backup_parent/nginx-sync-backup.XXXXXX")"
if [[ ! "$backup_dir" =~ ^/var/lib/apollo/nginx-sync-backup\.[A-Za-z0-9]+$ ]]; then
  echo "ERROR: Refusing unexpected nginx backup path: $backup_dir" >&2
  exit 1
fi
chmod 0700 "$backup_dir"
mkdir -m 0700 "$backup_dir/live" "$backup_dir/candidate"
cleanup_candidate() {
  local exit_status=$?
  trap - EXIT
  rm -rf -- "$stage_root" "$backup_dir"
  exit "$exit_status"
}
trap cleanup_candidate EXIT

cp -a -- "$nginx_root/." "$backup_dir/live/"
cp -a -- "$backup_dir/live/." "$backup_dir/candidate/"
candidate="$backup_dir/candidate"

# Build the complete candidate without touching the live bind-mounted tree.
rm -f -- \
  "$candidate/nginx.conf" \
  "$candidate/conf.d/00-default.conf" \
  "$candidate/conf.d/api-redirect.conf" \
  "$candidate/conf.d/10-dev.conf" \
  "$candidate/conf.d/local.conf.example" \
  "$candidate/conf.d"/app-*.ssl.conf \
  "$candidate/conf.d"/auth-*.ssl.conf \
  "$candidate/conf.d"/account-*.ssl.conf \
  "$candidate/conf.d"/signal-*.ssl.conf \
  "$candidate/local"/*.conf
rm -rf -- "$candidate/snippets"
mkdir -p "$candidate/conf.d" "$candidate/snippets" "$candidate/certs" "$candidate/local"
cp -a -- "$stage_source/." "$candidate/"
rm -f -- \
  "$candidate/conf.d/10-dev.conf" \
  "$candidate/conf.d/local.conf.example" \
  "$candidate/local"/*.conf

real_ip_candidate="$backup_dir/cloudflare-real-ip.conf"
if [ "$https_access_mode" = cloudflare ]; then
  {
    printf '%s\n' '# Managed by infra/scripts/bootstrap-vps.sh.'
    while IFS= read -r range || [ -n "$range" ]; do
      [ -n "$range" ] && printf 'set_real_ip_from %s;\n' "$range"
    done <<<"$cloudflare_ipv4"
    while IFS= read -r range || [ -n "$range" ]; do
      [ -n "$range" ] && printf 'set_real_ip_from %s;\n' "$range"
    done <<<"$cloudflare_ipv6"
    printf '%s\n' \
      'real_ip_header CF-Connecting-IP;' \
      'real_ip_recursive on;'
  } >"$real_ip_candidate"
else
  printf '%s\n' \
    '# Managed by infra/scripts/bootstrap-vps.sh.' \
    '# Direct-origin HTTPS: preserve nginx remote_addr and trust no forwarding header.' \
    >"$real_ip_candidate"
fi
install -m 0644 "$real_ip_candidate" "$candidate/snippets/cloudflare-real-ip.conf"

for required_file in "${required_files[@]}" snippets/cloudflare-real-ip.conf; do
  if [ ! -f "$candidate/$required_file" ] || [ ! -r "$candidate/$required_file" ]; then
    echo "ERROR: Candidate nginx tree is incomplete: $required_file" >&2
    rm -rf -- "$stage_root" "$backup_dir"
    exit 1
  fi
done
if [ "$https_access_mode" = cloudflare ] \
  && ! grep -Fxq 'real_ip_header CF-Connecting-IP;' "$candidate/snippets/cloudflare-real-ip.conf"; then
  echo "ERROR: Candidate nginx real-IP configuration is invalid." >&2
  rm -rf -- "$stage_root" "$backup_dir"
  exit 1
fi

container_exists=false
container_was_running=false
upstreams_ready=true
network_members=""
installed=false
if docker container inspect "$nginx_container" >/dev/null 2>&1; then
  container_exists=true
  if [ "$(docker inspect --format='{{.State.Running}}' "$nginx_container")" = true ]; then
    container_was_running=true
  fi
fi

if [ "$container_exists" = true ]; then
  network_members="$(docker network inspect --format='{{range .Containers}}{{println .Name}}{{end}}' apollo 2>/dev/null || true)"
  for upstream_container in apollo-platform apollo-billing apollo-signal; do
    if docker container inspect "$upstream_container" >/dev/null 2>&1 \
      && [ "$(docker inspect --format='{{.State.Running}}' "$upstream_container" 2>/dev/null || true)" != true ]; then
      upstreams_ready=false
      break
    fi
    if [ -n "$network_members" ]; then
      case $'\n'"$network_members"$'\n' in
        *$'\n'"$upstream_container"$'\n'*) ;;
        *) upstreams_ready=false; break ;;
      esac
    fi
  done
fi

if [ "$container_exists" = true ] && [ "$upstreams_ready" = false ]; then
  trap - EXIT
  rm -rf -- "$stage_root" "$backup_dir"
  echo "An nginx upstream is unavailable; preserving the live configuration until Terraform restores the application plane."
  exit 0
fi

rollback_nginx_sync() {
  local exit_status=$?
  local rollback_ok=true

  trap - EXIT
  set +e
  echo "ERROR: nginx synchronization failed; restoring $backup_dir/live." >&2
  if [ "$installed" = true ]; then
    if ! rsync -a --delete --delay-updates "$backup_dir/live/" "$nginx_root/"; then
      rollback_ok=false
    fi

    if [ "$container_exists" = true ]; then
      if [ "$container_was_running" = true ]; then
        docker start "$nginx_container" >/dev/null 2>&1 || rollback_ok=false
        docker exec "$nginx_container" nginx -t >/dev/null 2>&1 || rollback_ok=false
        docker exec "$nginx_container" nginx -s reload >/dev/null 2>&1 || rollback_ok=false
      else
        docker stop "$nginx_container" >/dev/null 2>&1 || true
        if docker start "$nginx_container" >/dev/null 2>&1 \
          && docker exec "$nginx_container" nginx -t >/dev/null 2>&1; then
          docker stop "$nginx_container" >/dev/null 2>&1 || rollback_ok=false
        else
          rollback_ok=false
        fi
      fi
    fi
  fi

  rm -rf -- "$stage_root"
  if [ "$rollback_ok" = true ]; then
    rm -rf -- "$backup_dir"
    echo "Previous nginx configuration restored." >&2
  else
    echo "ERROR: Automatic rollback was incomplete; protected backup retained at $backup_dir." >&2
  fi
  exit "$exit_status"
}
trap rollback_nginx_sync EXIT

# --delay-updates keeps replacements out of the live names until transfer is
# complete; the protected snapshot makes the multi-file update transactional.
installed=true
rsync -a --delete --delay-updates "$candidate/" "$nginx_root/"

if [ "$container_exists" = true ]; then
  if [ "$container_was_running" = true ]; then
    docker exec "$nginx_container" nginx -t
    docker exec "$nginx_container" nginx -s reload
  else
    docker start "$nginx_container" >/dev/null
    docker exec "$nginx_container" nginx -t
    docker stop "$nginx_container" >/dev/null
  fi
else
  echo "nginx container is not present yet; staged file validation passed and runtime validation is deferred to its first start."
fi

trap - EXIT
rm -rf -- "$stage_root" "$backup_dir"
NGINX_SYNC_REMOTE

trap - EXIT
REMOTE_NGINX_STAGE=""
NGINX_REMOTE_STAGE_B64=""
echo "nginx configuration synchronization completed."

# ── 5. Completion ─────────────────────────────────────────────────────────────
echo ""
echo "==> Bootstrap complete!"
echo ""
echo "If this script was invoked directly, continue with the supported orchestration:"
echo "  bash infra/setup.sh vps"
echo ""
echo "To inspect a saved plan without applying it:"
echo "  bash infra/setup.sh vps --plan-only"
echo ""
echo "When bootstrap-vps.sh is called by setup.sh, deployment continues automatically."
