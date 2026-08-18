#!/usr/bin/env bash
set -euo pipefail

release_id="${1:?release ID is required}"
email="${2:?ACME email is required}"
platform_host="${3:?platform host is required}"
signal_host="${4:?signal host is required}"
billing_host="${5:?billing host is required}"
[[ "$email" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+$ ]] || {
  echo 'ERROR: invalid ACME email address' >&2
  exit 2
}
compose_env="/opt/apollo/staged/$release_id/compose.env"
compose=(docker compose --env-file "$compose_env" -f "/opt/apollo/staged/$release_id/compose.yaml" --profile signal --profile tls)
compose_run() {
  env -i PATH="$PATH" HOME="${HOME:-/tmp}" \
    DOCKER_CONFIG="${DOCKER_CONFIG:-${HOME:-/tmp}/.docker}" \
    "${compose[@]}" "$@"
}

compose_run up -d postgres pgbouncer redis platform signal billing nginx
for host in "$platform_host" "$signal_host" "$billing_host"; do
  [[ "$host" =~ ^[A-Za-z0-9.-]+$ ]] || {
    echo "ERROR: invalid hostname $host" >&2
    exit 2
  }
  if ! compose_run run --rm --entrypoint test certbot -f "/etc/letsencrypt/live/$host/fullchain.pem"; then
    compose_run run --rm --entrypoint certbot certbot \
      certonly --webroot --webroot-path /var/www/certbot \
      --non-interactive --agree-tos --email "$email" -d "$host"
  fi
done

write_server() {
  local service="$1" host="$2" location_file="$3"
  local target="/opt/apollo/nginx/conf.d/$service.ssl.conf"
  cat >"$target.tmp" <<EOF
server {
    listen 443 ssl;
    http2 on;
    server_name $host;
    ssl_certificate /etc/letsencrypt/live/$host/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$host/privkey.pem;
    include /etc/nginx/snippets/ssl-params.conf;
    client_max_body_size 32m;
    include /etc/nginx/snippets/security-headers.conf;
    add_header X-Apollo-Service $service always;
    limit_conn conn_per_ip 100;
    include /etc/nginx/snippets/$location_file;
}
EOF
  chmod 0644 "$target.tmp"
  mv "$target.tmp" "$target"
}

write_server platform "$platform_host" locations-platform.conf
write_server signal "$signal_host" locations-signal.conf
write_server billing "$billing_host" locations-billing.conf
date -u +%s | compose_run run --rm -T --entrypoint sh certbot \
  -c 'umask 077; cat >/etc/letsencrypt/.apollo-last-success'
compose_run up -d --wait nginx certbot
compose_run exec -T nginx nginx -t
compose_run exec -T nginx nginx -s reload
