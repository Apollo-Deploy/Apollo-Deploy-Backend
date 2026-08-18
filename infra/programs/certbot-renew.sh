#!/bin/sh
set -eu
umask 077

success_marker=/etc/letsencrypt/.apollo-last-success

while :; do
  if certbot renew --webroot --webroot-path /var/www/certbot --quiet; then
    set -- /etc/letsencrypt/live/*/fullchain.pem
    if [ -e "$1" ]; then
      date -u +%s >"$success_marker.tmp"
      mv "$success_marker.tmp" "$success_marker"
    fi
    sleep 43200
  else
    echo 'certbot renewal failed; retrying in one hour' >&2
    sleep 3600
  fi
done
