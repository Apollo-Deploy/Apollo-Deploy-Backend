# =============================================================================
# Platform module — Platform API + nginx + certbot
# Stateless services only. Data services live in docker/infrastructure.
# Consumes: infra module outputs (container names for ordering).
# =============================================================================

terraform {
  required_version = ">= 1.10, < 2.0"

  required_providers {
    docker = {
      source  = "kreuzwerker/docker"
      version = "3.9.0"
    }
  }
}

locals {
  platform_url = var.auth.platform_url
  public_url   = coalesce(var.auth.platform_public_url, var.auth.platform_url)
  platform_domain = trimsuffix(
    trimprefix(coalesce(var.auth.platform_public_url, var.auth.platform_url), "https://"),
    "/",
  )

  dev_command = [
    "sh", "-c",
    "if [ ! -d node_modules ]; then bun install --frozen-lockfile --production --ignore-scripts; fi; exec bun --watch run src/index.ts",
  ]

  certbot_renewal_script = <<-SCRIPT
    set -eu
    state_dir=/etc/letsencrypt/.apollo-renewal-health
    state_file=$state_dir/status
    success_interval_seconds=43200
    failure_interval_seconds=3600

    if [ -L "$state_dir" ]; then
      echo 'certbot-renewal:state-directory-symlink' >&2
      exit 1
    fi
    mkdir -p -- "$state_dir"
    chmod 700 "$state_dir"

    read_state_value() {
      key=$1
      [ -f "$state_file" ] && [ ! -L "$state_file" ] || return 1
      sed -n "s/^$key=\\([0-9][0-9]*\\)$/\\1/p" "$state_file" | tail -n 1
    }

    write_state() {
      last_success_epoch=$1
      consecutive_failures=$2
      last_attempt_epoch=$3
      last_result=$4
      temporary_file=$state_file.tmp.$$
      umask 077
      {
        printf 'last_success_epoch=%s\n' "$last_success_epoch"
        printf 'consecutive_failures=%s\n' "$consecutive_failures"
        printf 'last_attempt_epoch=%s\n' "$last_attempt_epoch"
        printf 'last_result=%s\n' "$last_result"
      } >"$temporary_file"
      chmod 600 "$temporary_file"
      mv -f -- "$temporary_file" "$state_file"
    }

    trap 'exit 0' TERM INT
    while :; do
      attempt_epoch=$(date -u +%s)
      last_success_epoch=$(read_state_value last_success_epoch || true)
      consecutive_failures=$(read_state_value consecutive_failures || true)
      case "$last_success_epoch" in ''|*[!0-9]*) last_success_epoch=0 ;; esac
      case "$consecutive_failures" in ''|*[!0-9]*) consecutive_failures=0 ;; esac

      if certbot renew --webroot --webroot-path /var/www/certbot --quiet; then
        write_state "$attempt_epoch" 0 "$attempt_epoch" success
        sleep "$success_interval_seconds" &
      else
        consecutive_failures=$((consecutive_failures + 1))
        write_state "$last_success_epoch" "$consecutive_failures" "$attempt_epoch" failure
        echo "certbot-renewal:attempt-failed count=$consecutive_failures" >&2
        sleep "$failure_interval_seconds" &
      fi
      wait $!
    done
  SCRIPT

  certbot_healthcheck_script = <<-SCRIPT
    set -eu
    state_dir=/etc/letsencrypt/.apollo-renewal-health
    state_file=/etc/letsencrypt/.apollo-renewal-health/status
    certificate_observed_file=$state_dir/certificate-observed
    maximum_failures=3
    maximum_success_age_seconds=129600
    minimum_certificate_validity_seconds=1209600

    fail_health() {
      echo "certbot-health:$1" >&2
      exit 1
    }

    certificates_found=false
    for certificate in /etc/letsencrypt/live/*/fullchain.pem; do
      [ -e "$certificate" ] || continue
      certificates_found=true
    done
    if [ "$certificates_found" = false ]; then
      if [ -e "$certificate_observed_file" ] || [ -L "$certificate_observed_file" ]; then
        fail_health certificate-missing
      fi
      for renewal_configuration in /etc/letsencrypt/renewal/*.conf; do
        [ -e "$renewal_configuration" ] || continue
        fail_health certificate-missing
      done
      echo 'certbot-health:greenfield-no-certificate'
      exit 0
    fi

    [ -f "$state_file" ] && [ ! -L "$state_file" ] || fail_health state-missing
    read_state_value() {
      key=$1
      match_count=$(grep -Ec "^$key=[0-9]+$" "$state_file" || true)
      [ "$match_count" -eq 1 ] || fail_health state-malformed
      value=$(sed -n "s/^$key=\\([0-9][0-9]*\\)$/\\1/p" "$state_file")
      printf '%s\n' "$value"
    }

    last_success_epoch=$(read_state_value last_success_epoch)
    consecutive_failures=$(read_state_value consecutive_failures)
    [ "$consecutive_failures" -lt "$maximum_failures" ] \
      || fail_health repeated-renewal-failures

    now_epoch=$(date -u +%s)
    success_age_seconds=$((now_epoch - last_success_epoch))
    [ "$last_success_epoch" -gt 0 ] \
      && [ "$success_age_seconds" -ge 0 ] \
      && [ "$success_age_seconds" -le "$maximum_success_age_seconds" ] \
      || fail_health renewal-success-stale

    [ -d "$state_dir" ] && [ ! -L "$state_dir" ] || fail_health state-malformed
    [ ! -L "$certificate_observed_file" ] || fail_health state-malformed
    if [ -e "$certificate_observed_file" ] && [ ! -f "$certificate_observed_file" ]; then
      fail_health state-malformed
    fi
    if [ ! -f "$certificate_observed_file" ]; then
      temporary_file=$certificate_observed_file.tmp.$$
      umask 077
      printf 'observed\n' >"$temporary_file"
      chmod 600 "$temporary_file"
      mv -f -- "$temporary_file" "$certificate_observed_file"
    fi

    for certificate in /etc/letsencrypt/live/*/fullchain.pem; do
      [ -e "$certificate" ] || continue
      openssl x509 -checkend "$minimum_certificate_validity_seconds" -noout -in "$certificate" \
        >/dev/null 2>&1 || fail_health certificate-near-expiry
    done

    renewed_digest=$(openssl x509 -in "/etc/letsencrypt/live/${local.platform_domain}/fullchain.pem" -outform DER \
      | sha256sum | awk '{print $1}') \
      || fail_health renewed-certificate-unreadable
    served_digest=$(timeout 5 openssl s_client \
      -connect apollo-platform-nginx:443 \
      -servername "${local.platform_domain}" </dev/null 2>/dev/null \
      | openssl x509 -outform DER \
      | sha256sum | awk '{print $1}') \
      || fail_health served-certificate-unreadable
    if [ -z "$renewed_digest" ] || [ "$served_digest" != "$renewed_digest" ]; then
      echo "certbot-health:renewed-sha256=$renewed_digest served-sha256=$served_digest" >&2
      fail_health served-certificate-stale
    fi
    echo 'certbot-health:healthy'
  SCRIPT

  nginx_supervisor_script = <<-SCRIPT
    set -eu
    status_file=/tmp/apollo-nginx-reload-status
    certificate=/etc/letsencrypt/live/${local.platform_domain}/fullchain.pem
    reload_interval_seconds=21600

    certificate_digest() {
      sha256sum "$certificate" | awk '{print $1}'
    }

    write_reload_status() {
      result=$1
      digest=$2
      epoch=$3
      temporary_file=$status_file.tmp.$$
      umask 077
      {
        printf 'last_reload_result=%s\n' "$result"
        printf 'loaded_certificate_sha256=%s\n' "$digest"
        printf 'last_reload_epoch=%s\n' "$epoch"
      } >"$temporary_file"
      chmod 600 "$temporary_file"
      mv -f -- "$temporary_file" "$status_file"
    }

    initial_digest=none
    if [ -f "$certificate" ]; then
      initial_digest=$(certificate_digest)
    fi
    write_reload_status success "$initial_digest" "$(date -u +%s)"

    (
      while sleep "$reload_interval_seconds"; do
        reload_epoch=$(date -u +%s)
        if nginx -t && nginx -s reload; then
          loaded_digest=none
          if [ -f "$certificate" ]; then
            loaded_digest=$(certificate_digest)
          fi
          write_reload_status success "$loaded_digest" "$reload_epoch"
        else
          write_reload_status failure unknown "$reload_epoch"
          echo 'nginx-reload:failed' >&2
        fi
      done
    ) &
    exec nginx -g 'daemon off;'
  SCRIPT

  nginx_healthcheck_script = <<-SCRIPT
    set -eu
    status_file=/tmp/apollo-nginx-reload-status
    certificate=/etc/letsencrypt/live/${local.platform_domain}/fullchain.pem
    maximum_reload_age_seconds=22500

    fail_health() {
      echo "nginx-health:$1" >&2
      exit 1
    }

    wget --quiet --tries=1 --spider http://127.0.0.1/nginx-health \
      || fail_health http-unhealthy
    if [ ! -e "$certificate" ]; then
      echo 'nginx-health:greenfield-no-certificate'
      exit 0
    fi
    [ -f "$certificate" ] || fail_health certificate-malformed
    [ -f "$status_file" ] && [ ! -L "$status_file" ] \
      || fail_health reload-status-missing

    read_numeric_status() {
      key=$1
      count=$(grep -Ec "^$key=[0-9]+$" "$status_file" || true)
      [ "$count" -eq 1 ] || fail_health reload-status-malformed
      sed -n "s/^$key=\([0-9][0-9]*\)$/\1/p" "$status_file"
    }
    read_token_status() {
      key=$1
      count=$(grep -Ec "^$key=[a-z0-9]+$" "$status_file" || true)
      [ "$count" -eq 1 ] || fail_health reload-status-malformed
      sed -n "s/^$key=\([a-z0-9][a-z0-9]*\)$/\1/p" "$status_file"
    }

    reload_result=$(read_token_status last_reload_result)
    [ "$reload_result" = success ] || fail_health reload-failed
    loaded_digest=$(read_token_status loaded_certificate_sha256)
    renewed_digest=$(sha256sum "$certificate" | awk '{print $1}') \
      || fail_health certificate-unreadable
    [ "$loaded_digest" = "$renewed_digest" ] \
      || fail_health served-certificate-stale
    last_reload_epoch=$(read_numeric_status last_reload_epoch)
    now_epoch=$(date -u +%s)
    reload_age_seconds=$((now_epoch - last_reload_epoch))
    [ "$reload_age_seconds" -ge 0 ] \
      && [ "$reload_age_seconds" -le "$maximum_reload_age_seconds" ] \
      || fail_health reload-loop-stale
    echo 'nginx-health:healthy'
  SCRIPT
}

# ── Volumes ───────────────────────────────────────────────────────────────────
resource "docker_volume" "letsencrypt_certs" {
  count = var.certificate_volumes.certificates == null ? 1 : 0
  name  = "apollo-letsencrypt-certs"
}

resource "docker_volume" "certbot_webroot" {
  count = var.certificate_volumes.webroot == null ? 1 : 0
  name  = "apollo-certbot-webroot"
}

moved {
  from = docker_volume.letsencrypt_certs
  to   = docker_volume.letsencrypt_certs[0]
}
moved {
  from = docker_volume.certbot_webroot
  to   = docker_volume.certbot_webroot[0]
}

locals {
  certificates_volume_name    = coalesce(var.certificate_volumes.certificates, try(docker_volume.letsencrypt_certs[0].name, null))
  certbot_webroot_volume_name = coalesce(var.certificate_volumes.webroot, try(docker_volume.certbot_webroot[0].name, null))
}

# ── Images ────────────────────────────────────────────────────────────────────
# The platform image may be a locally built image ID (local env) or the VPS
# root's immutable digest-qualified registry reference.
resource "docker_image" "platform" {
  name         = var.image
  keep_locally = true
}

# nginx and certbot are always pulled from a registry — track their digests
# directly so pinned/floating tags re-pull when the upstream image changes.
data "docker_registry_image" "nginx" {
  name = var.nginx.image
}

data "docker_registry_image" "certbot" {
  name = var.certbot_image
}

resource "docker_image" "nginx" {
  name          = data.docker_registry_image.nginx.name
  pull_triggers = [data.docker_registry_image.nginx.sha256_digest]
  keep_locally  = true
}

resource "docker_image" "certbot" {
  name          = data.docker_registry_image.certbot.name
  pull_triggers = [data.docker_registry_image.certbot.sha256_digest]
  keep_locally  = true
}

# ── Platform API ──────────────────────────────────────────────────────────────
resource "docker_container" "platform" {
  name    = "apollo-platform"
  image   = docker_image.platform.image_id
  restart = "unless-stopped"

  stop_timeout = 30
  working_dir  = var.dev_mode ? "/app" : null
  command      = var.dev_mode ? local.dev_command : null

  env = [
    "NODE_ENV=${var.service.node_env}",
    "PORT=3000",
    "HOST=0.0.0.0",

    # Auth / URLs
    "PLATFORM_URL=${local.platform_url}",
    "PLATFORM_PUBLIC_URL=${local.public_url}",
    "CORS_ALLOWED_DOMAIN=${var.cors_allowed_domain}",
    "SESSION_SECRET=${var.auth.session_secret}",
    "AUTH_COOKIE_SECRET=${var.auth.cookie_secret}",
    "AUTH_SECURE_COOKIES=${var.auth.secure_cookies}",
    "AUTH_COOKIE_DOMAIN=${var.auth.cookie_domain}",
    "AUTH_LOGIN_URL=${var.auth.login_url}",
    "AUTH_CONSENT_URL=${var.auth.consent_url}",
    "AUTH_DISABLE_ORIGIN_CHECK=${var.auth.disable_origin_check}",
    "AUTH_DISABLE_CSRF_CHECK=${var.auth.disable_csrf_check}",
    "PLATFORM_CLIENT_ID=${var.oauth.client_id}",
    "PLATFORM_CLIENT_SECRET=${var.oauth.client_secret}",
    "OAUTH_TRUSTED_CLIENT_IDS=${var.oauth.trusted_client_ids}",
    "OAUTH_SERVICE_CLIENT_IDS=${var.oauth.service_client_ids}",

    # Database (points at pgbouncer)
    "DB_HOST=${var.db.host}",
    "DB_PORT=${var.db.port}",
    "DB_USER=${var.db.user}",
    "DB_PASSWORD=${var.db.password}",
    "DB_NAME=${var.db.name}",
    "DB_POOL_MAX=10",
    "DB_VERIFIER_ENABLED=${var.db.verifier_enabled}",
    "DB_VERIFIER_HOST=${var.db.verifier_host}",
    "DB_VERIFIER_USER=${var.db.verifier_user}",
    "DB_VERIFIER_PASSWORD=${var.db.verifier_password}",

    # Signal DB name (platform needs to know it for cross-DB queries)
    "SIGNAL_DB_NAME=${var.service.signal_db_name}",

    # Redis
    "REDIS_HOST=${var.redis.host}",
    "REDIS_PORT=${var.redis.port}",
    "REDIS_PASSWORD=${var.redis.password}",
    "REDIS_TLS=false",

    # Service
    "BILLING_BASE_URL=${var.service.billing_base_url}",
    "SIGNAL_BASE_URL=${var.service.signal_base_url}",
    "METRICS_ENABLED=${var.service.metrics_enabled}",
  ]

  log_driver = "local"
  log_opts = {
    max-size = "10m"
    max-file = "3"
  }

  networks_advanced {
    name    = var.network_name
    aliases = ["platform"] # nginx config upstream uses "platform:3000"
  }

  healthcheck {
    test         = ["CMD", "bun", "-e", "const response = await fetch('http://127.0.0.1:3000/health'); if (!response.ok) process.exit(1)"]
    interval     = "15s"
    timeout      = "5s"
    retries      = 5
    start_period = var.dev_mode ? "3m0s" : "30s"
  }

  read_only = var.dev_mode ? false : true

  dynamic "volumes" {
    for_each = var.dev_mode ? { app = var.source_dir, npmrc = pathexpand("~/.npmrc") } : {}
    content {
      host_path      = volumes.value
      container_path = volumes.key == "npmrc" ? "/app/.npmrc" : "/app"
      read_only      = volumes.key == "npmrc"
    }
  }

  mounts {
    target = "/tmp"
    type   = "tmpfs"
    tmpfs_options {
      size_bytes = 104857600 # 100 MB
    }
  }

  dynamic "mounts" {
    for_each = var.dev_mode ? [] : [1]
    content {
      target = "/app/.cache"
      type   = "tmpfs"
      tmpfs_options {
        size_bytes = 52428800 # 50 MB
      }
    }
  }

  security_opts = ["no-new-privileges:true"]

  capabilities {
    drop = ["ALL"]
  }

  labels {
    label = "managed-by"
    value = "terraform"
  }

  labels {
    label = "org.opencontainers.image.revision"
    value = var.source_commit != "" ? var.source_commit : "local"
  }

  lifecycle {
    ignore_changes = [shm_size, ipc_mode, runtime, stop_signal, stop_timeout]
  }

  # Ordering relative to infra (Postgres/Redis) is handled by the caller via
  # `depends_on = [module.infra]` on this module. The deploy reconciliation
  # script performs migration and health checks after Terraform converges.
}

# ── nginx ─────────────────────────────────────────────────────────────────────
resource "docker_container" "nginx" {
  name  = "apollo-platform-nginx"
  image = docker_image.nginx.image_id
  # Docker must not auto-restore this published listener before the host's
  # Cloudflare origin policy is active. bootstrap-vps.sh starts it from Docker's
  # ordered post-policy systemd hook after every daemon start.
  restart = "on-failure"

  stop_timeout = 10

  # nginx loads renewed certificates only on reload. The supervisor records the
  # exact certificate digest loaded by each successful reload, and health fails
  # if the loop stops, reload fails, or the renewed file no longer matches that
  # loaded generation. This avoids giving Certbot access to the Docker socket.
  entrypoint = ["/bin/sh", "-c"]
  command    = [local.nginx_supervisor_script]

  ports {
    internal = 80
    external = var.nginx.http_port
    ip       = var.nginx.bind_ip
  }

  ports {
    internal = 443
    external = var.nginx.https_port
    ip       = var.nginx.bind_ip
  }

  log_driver = "local"
  log_opts = {
    max-size = "10m"
    max-file = "3"
  }

  volumes {
    host_path      = "${var.nginx.conf_dir}/nginx.conf"
    container_path = "/etc/nginx/nginx.conf"
    read_only      = true
  }

  volumes {
    host_path      = "${var.nginx.conf_dir}/conf.d"
    container_path = "/etc/nginx/conf.d"
    read_only      = true
  }

  volumes {
    host_path      = "${var.nginx.conf_dir}/snippets"
    container_path = "/etc/nginx/snippets"
    read_only      = true
  }

  volumes {
    host_path      = "${var.nginx.conf_dir}/certs"
    container_path = "/etc/nginx/certs"
    read_only      = true
  }

  volumes {
    host_path      = "${var.nginx.conf_dir}/local"
    container_path = "/etc/nginx/local"
    read_only      = true
  }

  volumes {
    volume_name    = local.certificates_volume_name
    container_path = "/etc/letsencrypt"
    read_only      = true
  }

  volumes {
    volume_name    = local.certbot_webroot_volume_name
    container_path = "/var/www/certbot"
    read_only      = true
  }

  networks_advanced {
    name = var.network_name
  }

  healthcheck {
    test         = ["CMD-SHELL", local.nginx_healthcheck_script]
    interval     = "15s"
    timeout      = "5s"
    retries      = 3
    start_period = "10s"
  }

  read_only = true

  mounts {
    target = "/var/cache/nginx"
    type   = "tmpfs"
    tmpfs_options {
      size_bytes = 104857600 # 100 MB
    }
  }

  mounts {
    target = "/var/run"
    type   = "tmpfs"
    tmpfs_options {
      size_bytes = 10485760 # 10 MB
    }
  }

  mounts {
    target = "/tmp"
    type   = "tmpfs"
    tmpfs_options {
      size_bytes = 52428800 # 50 MB
    }
  }

  security_opts = ["no-new-privileges:true"]

  capabilities {
    drop = ["ALL"]
    add  = ["CHOWN", "SETUID", "SETGID", "NET_BIND_SERVICE"]
  }

  labels {
    label = "managed-by"
    value = "terraform"
  }

  lifecycle {
    # Docker reports capability names with a CAP_ prefix; ignore only that
    # representational drift. Port bindings remain managed security controls.
    ignore_changes = [shm_size, ipc_mode, runtime, stop_signal, stop_timeout, capabilities]
  }

  depends_on = [docker_container.platform]
}

# ── certbot ───────────────────────────────────────────────────────────────────
resource "docker_container" "certbot" {
  name    = "apollo-platform-certbot"
  image   = docker_image.certbot.image_id
  restart = "unless-stopped"

  log_driver = "local"
  log_opts = {
    max-size = "10m"
    max-file = "3"
  }

  # Auto-renew every 12 hours, retry hourly after failures, and persist a
  # machine-readable success/failure record beside the certificates.
  entrypoint = ["/bin/sh", "-c"]
  command    = [local.certbot_renewal_script]

  volumes {
    volume_name    = local.certificates_volume_name
    container_path = "/etc/letsencrypt"
  }

  volumes {
    volume_name    = local.certbot_webroot_volume_name
    container_path = "/var/www/certbot"
  }

  networks_advanced {
    name = var.network_name
  }

  healthcheck {
    test         = ["CMD-SHELL", local.certbot_healthcheck_script]
    interval     = "5m0s"
    timeout      = "10s"
    retries      = 2
    start_period = "1m0s"
  }

  read_only = true

  mounts {
    target = "/tmp"
    type   = "tmpfs"
    tmpfs_options {
      size_bytes = 52428800
    }
  }

  mounts {
    target = "/var/log/letsencrypt"
    type   = "tmpfs"
    tmpfs_options {
      size_bytes = 52428800
    }
  }

  mounts {
    target = "/var/lib/letsencrypt"
    type   = "tmpfs"
    tmpfs_options {
      size_bytes = 52428800
    }
  }

  security_opts = ["no-new-privileges:true"]

  capabilities {
    drop = ["ALL"]
  }

  labels {
    label = "managed-by"
    value = "terraform"
  }

  # docker_container healthcheck updates are not reliably applied to a running
  # container by Docker. Bind the hostname into replacement-triggering labels
  # so a certificate lineage change also replaces the certbot process.
  labels {
    label = "apollo.deploy/certificate-domain"
    value = local.platform_domain
  }

  lifecycle {
    ignore_changes = [shm_size, ipc_mode, runtime, stop_signal, stop_timeout]
  }
}
