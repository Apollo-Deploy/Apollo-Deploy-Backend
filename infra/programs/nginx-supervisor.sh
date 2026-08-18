#!/bin/sh
set -eu

certificate_digest() {
  find -L /etc/letsencrypt/live -name fullchain.pem -type f -exec sha256sum {} \; 2>/dev/null \
    | sort \
    | sha256sum \
    | awk '{print $1}'
}

touch /tmp/apollo-nginx-reload-success
last_digest="$(certificate_digest)"

(
  while sleep 300; do
    current_digest="$(certificate_digest)"
    if [ "$current_digest" != "$last_digest" ]; then
      if nginx -t && nginx -s reload; then
        last_digest="$current_digest"
        touch /tmp/apollo-nginx-reload-success
      else
        rm -f /tmp/apollo-nginx-reload-success
      fi
    fi
  done
) &

exec nginx -g 'daemon off;'
