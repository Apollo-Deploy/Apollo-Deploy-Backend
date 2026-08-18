#!/usr/bin/env bash
# Issue the first production certificate and install deterministic nginx vhosts.
# Subsequent renewals are handled by the Terraform-managed certbot container.
set -euo pipefail

SSH_PORT=22
SSH_KEY_PATH=""
while getopts "p:i:" opt; do
  case "$opt" in
    p) SSH_PORT="$OPTARG" ;;
    i) SSH_KEY_PATH="$OPTARG" ;;
    *) echo "Usage: $0 [-p ssh_port] [-i ssh_key] user@host base-domain email" >&2; exit 1 ;;
  esac
done
shift $((OPTIND - 1))

if [ "$#" -ne 3 ] && [ "$#" -ne 6 ]; then
  echo "Usage: $0 [-p ssh_port] [-i ssh_key] user@host base-domain email [platform-host signal-host billing-host]" >&2
  exit 1
fi

REMOTE="$1"
BASE_DOMAIN="$2"
EMAIL="$3"

if ! [[ "$SSH_PORT" =~ ^[0-9]+$ ]] || ((SSH_PORT < 1 || SSH_PORT > 65535)); then
  echo "ERROR: SSH port must be an integer between 1 and 65535." >&2
  exit 1
fi
if [[ "$SSH_KEY_PATH" == \~/* ]]; then
  SSH_KEY_PATH="$HOME/${SSH_KEY_PATH#\~/}"
fi
if [ -n "$SSH_KEY_PATH" ] && [ ! -r "$SSH_KEY_PATH" ]; then
  echo "ERROR: SSH private key is not readable: $SSH_KEY_PATH" >&2
  exit 1
fi
if ! [[ "$REMOTE" =~ ^[a-z_][a-z0-9_-]*@([A-Za-z0-9][A-Za-z0-9.-]*|\[[0-9A-Fa-f:]+\])$ ]]; then
  echo "ERROR: target must be user@hostname, user@IPv4, or user@[IPv6]." >&2
  exit 1
fi
if ! [[ "$BASE_DOMAIN" =~ ^([A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]]; then
  echo "ERROR: base-domain is not a valid DNS domain." >&2
  exit 1
fi
if ! [[ "$EMAIL" =~ ^[A-Za-z0-9][A-Za-z0-9._%+-]*@[A-Za-z0-9][A-Za-z0-9.-]*\.[A-Za-z]{2,63}$ ]]; then
  echo "ERROR: email is not valid." >&2
  exit 1
fi

SSH=(ssh -p "$SSH_PORT" -o StrictHostKeyChecking=yes)
if [ -n "$SSH_KEY_PATH" ]; then
  SSH+=(-i "$SSH_KEY_PATH")
fi
PLATFORM_DOMAIN="${4:-api.${BASE_DOMAIN}}"
SIGNAL_DOMAIN="${5:-api.signal.${BASE_DOMAIN}}"
BILLING_DOMAIN="${6:-api.billing.${BASE_DOMAIN}}"
NGINX_CONTAINER="apollo-platform-nginx"
SAFE_BASE_DOMAIN="${BASE_DOMAIN//./-}"
ROLLBACK_DIR=""

if ! "${SSH[@]}" "$REMOTE" \
  "test -f /opt/apollo/platform/nginx/snippets/cloudflare-real-ip.conf && test ! -L /opt/apollo/platform/nginx/snippets/cloudflare-real-ip.conf && test -r /opt/apollo/platform/nginx/snippets/cloudflare-real-ip.conf"; then
  echo "ERROR: The managed real-IP snippet is unavailable; run bootstrap-vps.sh before TLS setup." >&2
  exit 1
fi

rollback_tls() {
  local exit_status=$?

  trap - EXIT
  set +e
  echo "ERROR: TLS setup failed; restoring the previous nginx configuration." >&2
  if [ -n "$ROLLBACK_DIR" ]; then
    if ! "${SSH[@]}" "$REMOTE" bash -s -- "$ROLLBACK_DIR" "$NGINX_CONTAINER" <<'TLS_ROLLBACK_REMOTE'
set -euo pipefail
rollback_dir="$1"
nginx_container="$2"
nginx_root=/opt/apollo/platform/nginx
live_config="$nginx_root/conf.d/20-production.conf"

case "$rollback_dir" in
  "$nginx_root"/.tls-rollback.*) ;;
  *) exit 1 ;;
esac

if [ ! -f "$rollback_dir/snapshot-ready" ] \
  || [ -L "$rollback_dir/snapshot-ready" ]; then
  # Snapshot setup never changes the production vhost before this marker. An
  # incomplete snapshot therefore has no authority to replace or remove it.
  echo "Incomplete TLS snapshot; leaving the live production vhost untouched." >&2
elif [ -f "$rollback_dir/original-present" ] \
  && [ ! -L "$rollback_dir/original-present" ] \
  && [ ! -e "$rollback_dir/original-absent" ]; then
  [ -f "$rollback_dir/20-production.conf.previous" ] \
    && [ ! -L "$rollback_dir/20-production.conf.previous" ]
  cp -p -- "$rollback_dir/20-production.conf.previous" "$live_config"
elif [ -f "$rollback_dir/original-absent" ] \
  && [ ! -L "$rollback_dir/original-absent" ] \
  && [ ! -e "$rollback_dir/original-present" ]; then
  rm -f -- "$live_config"
else
  echo "ERROR: TLS snapshot has ambiguous original-state markers." >&2
  exit 1
fi

if [ -d "$rollback_dir/stale" ]; then
  while IFS= read -r -d '' saved_file; do
    relative_path="${saved_file#"$rollback_dir/stale/"}"
    mkdir -p -- "$nginx_root/$(dirname "$relative_path")"
    mv -- "$saved_file" "$nginx_root/$relative_path"
  done < <(find "$rollback_dir/stale" \( -type f -o -type l \) -print0)
fi

docker restart "$nginx_container" >/dev/null 2>&1 \
  || docker start "$nginx_container" >/dev/null 2>&1
docker exec "$nginx_container" nginx -t >/dev/null 2>&1
rm -rf -- "$rollback_dir"
TLS_ROLLBACK_REMOTE
    then
      echo "ERROR: Automatic nginx rollback also failed; restore $ROLLBACK_DIR manually before resuming traffic." >&2
    fi
  else
    "${SSH[@]}" "$REMOTE" "docker start '$NGINX_CONTAINER' >/dev/null 2>&1 || true"
  fi
  exit "$exit_status"
}
trap rollback_tls EXIT

echo "==> Stopping nginx temporarily for the ACME standalone challenge..."
"${SSH[@]}" "$REMOTE" "docker stop '$NGINX_CONTAINER' >/dev/null 2>&1 || true"

echo "==> Issuing or reusing the Let's Encrypt certificate..."
"${SSH[@]}" "$REMOTE" docker run --rm --pull=never \
  --name apollo-certbot-bootstrap \
  --publish 80:80 \
  --volume apollo-letsencrypt-certs:/etc/letsencrypt \
  certbot/certbot:v2.11.0@sha256:ddf9e5d226a56e886986838fa0ebedc0237511c78664352e8d0f4346ee022cd8 certonly \
  --standalone \
  --non-interactive \
  --agree-tos \
  --no-eff-email \
  --keep-until-expiring \
  --email "$EMAIL" \
  --domain "$PLATFORM_DOMAIN" \
  --domain "$SIGNAL_DOMAIN" \
  --domain "$BILLING_DOMAIN"

echo "==> Staging the previous nginx configuration for rollback..."
ROLLBACK_DIR="$("${SSH[@]}" "$REMOTE" bash -s -- "$SAFE_BASE_DOMAIN" <<'TLS_SNAPSHOT_REMOTE'
set -euo pipefail
safe_base_domain="$1"
nginx_root=/opt/apollo/platform/nginx
live_config="$nginx_root/conf.d/20-production.conf"
rollback_dir=""

cleanup_incomplete_snapshot() {
  local exit_status=$?
  trap - EXIT
  if [ "$exit_status" -ne 0 ] && [ -n "$rollback_dir" ]; then
    # Snapshot creation is copy-only. Its identity is not returned until the
    # ready marker exists, so an interrupted snapshot has no live mutations to
    # undo and can be discarded safely.
    rm -rf -- "$rollback_dir"
  fi
  exit "$exit_status"
}
trap cleanup_incomplete_snapshot EXIT

rollback_dir="$(umask 077 && mktemp -d "$nginx_root/.tls-rollback.XXXXXX")"
mkdir -p "$rollback_dir/stale"

if [ -e "$live_config" ] || [ -L "$live_config" ]; then
  touch -- "$rollback_dir/original-present"
  cp -p -- "$live_config" "$rollback_dir/20-production.conf.previous"
else
  touch -- "$rollback_dir/original-absent"
fi

stale_files=(
  "$nginx_root/conf.d/10-dev.conf"
  "$nginx_root/conf.d/app-${safe_base_domain}.ssl.conf"
  "$nginx_root/conf.d/auth-${safe_base_domain}.ssl.conf"
  "$nginx_root/conf.d/account-${safe_base_domain}.ssl.conf"
  "$nginx_root/conf.d/signal-${safe_base_domain}.ssl.conf"
)
shopt -s nullglob
stale_files+=("$nginx_root"/local/*.conf)
shopt -u nullglob
for stale_file in "${stale_files[@]}"; do
  if [ -e "$stale_file" ] || [ -L "$stale_file" ]; then
    relative_path="${stale_file#"$nginx_root/"}"
    mkdir -p -- "$rollback_dir/stale/$(dirname "$relative_path")"
    cp -a -- "$stale_file" "$rollback_dir/stale/$relative_path"
  fi
done
touch -- "$rollback_dir/snapshot-ready"
trap - EXIT
printf '%s\n' "$rollback_dir"
TLS_SNAPSHOT_REMOTE
)"
if [[ ! "$ROLLBACK_DIR" =~ ^/opt/apollo/platform/nginx/\.tls-rollback\.[A-Za-z0-9]+$ ]]; then
  echo "ERROR: Refusing unexpected remote rollback path: $ROLLBACK_DIR" >&2
  exit 1
fi

# The snapshot phase above is deliberately copy-only. Now that the caller has
# a validated rollback identity and its EXIT trap can address it, remove only
# the stale paths represented by that complete snapshot.
"${SSH[@]}" "$REMOTE" bash -s -- "$ROLLBACK_DIR" "$SAFE_BASE_DOMAIN" <<'TLS_REMOVE_STALE_REMOTE'
set -euo pipefail
rollback_dir="$1"
safe_base_domain="$2"
nginx_root=/opt/apollo/platform/nginx
stale_root="$rollback_dir/stale"

case "$rollback_dir" in
  "$nginx_root"/.tls-rollback.*) ;;
  *) exit 1 ;;
esac
[ -d "$rollback_dir" ] && [ ! -L "$rollback_dir" ] \
  && [ -f "$rollback_dir/snapshot-ready" ] \
  && [ ! -L "$rollback_dir/snapshot-ready" ] \
  || exit 1

validate_stale_path() {
  case "$1" in
    conf.d/10-dev.conf \
      |conf.d/app-"$safe_base_domain".ssl.conf \
      |conf.d/auth-"$safe_base_domain".ssl.conf \
      |conf.d/account-"$safe_base_domain".ssl.conf \
      |conf.d/signal-"$safe_base_domain".ssl.conf \
      |local/*.conf) ;;
    *) return 1 ;;
  esac
}

# Validate the complete manifest before the first deletion.
while IFS= read -r -d '' saved_file; do
  relative_path="${saved_file#"$stale_root/"}"
  validate_stale_path "$relative_path"
done < <(find "$stale_root" \( -type f -o -type l \) -print0)

while IFS= read -r -d '' saved_file; do
  relative_path="${saved_file#"$stale_root/"}"
  rm -f -- "$nginx_root/$relative_path"
done < <(find "$stale_root" \( -type f -o -type l \) -print0)
TLS_REMOVE_STALE_REMOTE

echo "==> Installing API-only production nginx vhosts..."
{
  printf '%s\n' '# Managed by infra/scripts/setup-vps-tls.sh. Re-run after changing base_domain.'
  printf '%s\n' \
    'server {' \
    '    listen 443 ssl default_server;' \
    '    http2 on;' \
    '    server_name _;' \
    "    ssl_certificate /etc/letsencrypt/live/${PLATFORM_DOMAIN}/fullchain.pem;" \
    "    ssl_certificate_key /etc/letsencrypt/live/${PLATFORM_DOMAIN}/privkey.pem;" \
    '    include /etc/nginx/snippets/ssl-params.conf;' \
    '    include /etc/nginx/snippets/cloudflare-real-ip.conf;' \
    '    return 444;' \
    '}' \
    ''
  for service in platform signal billing; do
    case "$service" in
      platform) domain="$PLATFORM_DOMAIN" ;;
      signal) domain="$SIGNAL_DOMAIN" ;;
      billing) domain="$BILLING_DOMAIN" ;;
    esac
    printf '%s\n' \
      'server {' \
      '    listen 80;' \
      "    server_name ${domain};" \
      '    include /etc/nginx/snippets/acme-challenge.conf;' \
      "    location / { return 301 https://\$host\$request_uri; }" \
      '}' \
      '' \
      'server {' \
      '    listen 443 ssl;' \
      '    http2 on;' \
      "    server_name ${domain};" \
      "    ssl_certificate /etc/letsencrypt/live/${PLATFORM_DOMAIN}/fullchain.pem;" \
      "    ssl_certificate_key /etc/letsencrypt/live/${PLATFORM_DOMAIN}/privkey.pem;" \
      '    include /etc/nginx/snippets/ssl-params.conf;' \
      '    include /etc/nginx/snippets/cloudflare-real-ip.conf;' \
      '    client_max_body_size 32m;' \
      '    include /etc/nginx/snippets/security-headers.conf;' \
      '    limit_conn conn_per_ip 100;' \
      "    include /etc/nginx/snippets/locations-${service}.conf;" \
      '}' \
      ''
  done
} | "${SSH[@]}" "$REMOTE" \
  "umask 077; cat > '$ROLLBACK_DIR/20-production.conf.candidate'; chmod 600 '$ROLLBACK_DIR/20-production.conf.candidate'; mv -- '$ROLLBACK_DIR/20-production.conf.candidate' /opt/apollo/platform/nginx/conf.d/20-production.conf; chmod 644 /opt/apollo/platform/nginx/conf.d/20-production.conf"

echo "==> Starting nginx with the candidate configuration..."
"${SSH[@]}" "$REMOTE" "docker start '$NGINX_CONTAINER' >/dev/null"

echo "==> Validating nginx configuration..."
"${SSH[@]}" "$REMOTE" "docker exec '$NGINX_CONTAINER' nginx -t"
"${SSH[@]}" "$REMOTE" "test \"\$(docker inspect --format='{{.State.Running}}' '$NGINX_CONTAINER')\" = true"

trap - EXIT
"${SSH[@]}" "$REMOTE" "rm -rf -- '$ROLLBACK_DIR'"
ROLLBACK_DIR=""
echo "==> TLS is configured for all API hosts."
