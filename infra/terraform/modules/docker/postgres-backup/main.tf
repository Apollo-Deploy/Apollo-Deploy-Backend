locals {
  labels = merge(var.labels, {
    "managed-by"                = "terraform"
    "com.apollo-deploy.service" = "postgres-backup"
    "com.apollo-deploy.data"    = "backup"
  })

  backup_script = <<-SCRIPT
    set -eu
    umask 077

    temporary_path=""
    generation_marker=/tmp/current-generation-success
    generation_marker_tmp=/tmp/.current-generation-success.tmp

    cleanup_current_dump() {
      if [ -n "$temporary_path" ]; then
        rm -f "$temporary_path"
      fi
    }

    remove_stale_temporary_files() {
      for stale_path in /backups/.postgres-*.sql.tmp /backups/.last-success.tmp; do
        if [ -e "$stale_path" ]; then
          rm -f "$stale_path"
        fi
      done
    }

    prune_old_backups() {
      # The UTC timestamp makes shell glob order equal chronological order.
      set -- /backups/postgres-*.sql
      if [ ! -e "$1" ]; then
        return 0
      fi

      while [ "$#" -gt "$BACKUP_RETENTION_COUNT" ]; do
        oldest_path="$1"
        shift
        rm -f "$oldest_path" || return 1
      done

      return 0
    }

    create_backup() {
      # A success from an older container generation must never make this
      # generation healthy. Every new attempt clears its ephemeral proof and
      # recreates it only after this attempt publishes a complete backup.
      rm -f "$generation_marker" "$generation_marker_tmp" || return 1
      timestamp="$(date -u '+%Y%m%dT%H%M%SZ')" || return 1
      final_path="/backups/postgres-$timestamp.sql"

      # Avoid replacing a completed backup if a container restarts in the same second.
      while [ -e "$final_path" ]; do
        sleep 1 || return 1
        timestamp="$(date -u '+%Y%m%dT%H%M%SZ')" || return 1
        final_path="/backups/postgres-$timestamp.sql"
      done

      temporary_path="/backups/.postgres-$timestamp-$$.sql.tmp"
      rm -f "$temporary_path" || return 1

      printf '%s\n' "Starting PostgreSQL cluster backup at $timestamp"
      if pg_dumpall \
        --no-password \
        --clean \
        --if-exists \
        --quote-all-identifiers \
        --file="$temporary_path"; then
        chmod 0600 "$temporary_path" || {
          printf '%s\n' "Could not secure temporary backup file" >&2
          cleanup_current_dump
          temporary_path=""
          return 1
        }
        sync || {
          printf '%s\n' "Could not flush temporary backup file" >&2
          cleanup_current_dump
          temporary_path=""
          return 1
        }
        mv "$temporary_path" "$final_path" || {
          printf '%s\n' "Could not publish completed backup file" >&2
          cleanup_current_dump
          temporary_path=""
          return 1
        }
        temporary_path=""

        prune_old_backups || {
          printf '%s\n' "Could not enforce PostgreSQL backup retention" >&2
          return 1
        }

        success_epoch="$(date -u '+%s')" || return 1
        printf '%s\n' "$success_epoch" > /backups/.last-success.tmp || return 1
        chmod 0600 /backups/.last-success.tmp || return 1
        mv /backups/.last-success.tmp /backups/.last-success || return 1
        sync || return 1

        printf '%s\n' "$success_epoch" > "$generation_marker_tmp" || return 1
        chmod 0600 "$generation_marker_tmp" || return 1
        mv "$generation_marker_tmp" "$generation_marker" || return 1

        printf '%s\n' "Completed PostgreSQL cluster backup: $final_path"
        return 0
      else
        status="$?"
        cleanup_current_dump
        temporary_path=""
        printf '%s\n' "PostgreSQL cluster backup failed with exit status $status" >&2
        return "$status"
      fi
    }

    trap 'cleanup_current_dump; exit 0' INT TERM
    trap 'cleanup_current_dump' EXIT

    remove_stale_temporary_files
    rm -f "$generation_marker" "$generation_marker_tmp"
    while :; do
      if create_backup; then
        delay="$BACKUP_INTERVAL_SECONDS"
      else
        delay="$BACKUP_RETRY_INTERVAL_SECONDS"
      fi
      sleep "$delay"
    done
  SCRIPT

  healthcheck_script = <<-SCRIPT
    marker=/backups/.last-success
    generation_marker=/tmp/current-generation-success
    test -r "$marker" && test -r "$generation_marker" || exit 1
    last_success="$(cat "$marker")" || exit 1
    generation_success="$(cat "$generation_marker")" || exit 1
    case "$last_success" in
      ''|*[!0-9]*) exit 1 ;;
    esac
    case "$generation_success" in
      ''|*[!0-9]*) exit 1 ;;
    esac
    test "$generation_success" = "$last_success" || exit 1
    now="$(date -u '+%s')" || exit 1
    age="$((now - last_success))"
    test "$age" -ge 0 && test "$age" -le "$BACKUP_MAX_AGE_SECONDS"
  SCRIPT

  offsite_healthcheck_script = <<-SCRIPT
    marker=/tmp/last-offsite-success
    test -r "$marker" || exit 1
    last_success="$(cat "$marker")" || exit 1
    case "$last_success" in
      ''|*[!0-9]*) exit 1 ;;
    esac
    now="$(date -u '+%s')" || exit 1
    age="$((now - last_success))"
    test "$age" -ge 0 && test "$age" -le "$OFFSITE_MAX_AGE_SECONDS"
  SCRIPT
}

data "docker_registry_image" "postgres_client" {
  name = var.postgres_client_image
}

resource "docker_image" "postgres_client" {
  name          = data.docker_registry_image.postgres_client.name
  pull_triggers = [data.docker_registry_image.postgres_client.sha256_digest]
  keep_locally  = true
}

resource "docker_volume" "backups" {
  name   = var.backup_volume_name
  driver = "local"

  dynamic "labels" {
    for_each = local.labels
    content {
      label = labels.key
      value = labels.value
    }
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "docker_container" "backup" {
  name    = var.container_name
  image   = docker_image.postgres_client.image_id
  restart = "unless-stopped"

  init           = true
  privileged     = false
  remove_volumes = false
  wait           = false

  command = ["/bin/sh", "-c", local.backup_script]

  env = [
    "PGHOST=${var.postgres_host}",
    "PGPORT=${var.postgres_port}",
    "PGUSER=${var.postgres_user}",
    "PGPASSWORD=${var.postgres_password}",
    "PGDATABASE=${var.postgres_database}",
    "PGSSLMODE=${var.postgres_sslmode}",
    "PGCONNECT_TIMEOUT=${var.connection_timeout_seconds}",
    "PGAPPNAME=apollo-postgres-backup",
    "LC_ALL=C",
    "BACKUP_INTERVAL_SECONDS=${var.schedule.interval_seconds}",
    "BACKUP_RETRY_INTERVAL_SECONDS=${var.schedule.retry_interval_seconds}",
    "BACKUP_RETENTION_COUNT=${var.schedule.retention_count}",
    "BACKUP_MAX_AGE_SECONDS=${var.schedule.max_backup_age_seconds}",
  ]

  networks_advanced {
    name = var.network_name
  }

  volumes {
    volume_name    = docker_volume.backups.name
    container_path = "/backups"
    read_only      = false
  }

  tmpfs = {
    "/tmp" = "rw,noexec,nosuid,nodev,size=64m,mode=1777"
  }

  read_only     = true
  security_opts = ["no-new-privileges:true"]

  capabilities {
    drop = ["ALL"]
  }

  log_driver = "local"
  log_opts = {
    "max-size" = "10m"
    "max-file" = "3"
  }

  healthcheck {
    test = ["CMD-SHELL", local.healthcheck_script]
    interval = var.schedule.healthcheck_interval_seconds >= 3600 ? format(
      "%dh%dm%ds",
      floor(var.schedule.healthcheck_interval_seconds / 3600),
      floor((var.schedule.healthcheck_interval_seconds % 3600) / 60),
      var.schedule.healthcheck_interval_seconds % 60,
      ) : var.schedule.healthcheck_interval_seconds >= 60 ? format(
      "%dm%ds",
      floor(var.schedule.healthcheck_interval_seconds / 60),
      var.schedule.healthcheck_interval_seconds % 60,
    ) : "${var.schedule.healthcheck_interval_seconds}s"
    timeout = "${var.schedule.healthcheck_timeout_seconds}s"
    retries = var.schedule.healthcheck_retries
    start_period = var.schedule.healthcheck_start_period_seconds >= 3600 ? format(
      "%dh%dm%ds",
      floor(var.schedule.healthcheck_start_period_seconds / 3600),
      floor((var.schedule.healthcheck_start_period_seconds % 3600) / 60),
      var.schedule.healthcheck_start_period_seconds % 60,
      ) : var.schedule.healthcheck_start_period_seconds >= 60 ? format(
      "%dm%ds",
      floor(var.schedule.healthcheck_start_period_seconds / 60),
      var.schedule.healthcheck_start_period_seconds % 60,
    ) : "${var.schedule.healthcheck_start_period_seconds}s"
  }

  dynamic "labels" {
    for_each = local.labels
    content {
      label = labels.key
      value = labels.value
    }
  }

  stop_timeout = 30

  lifecycle {
    # Docker fills these runtime defaults differently across daemon versions.
    ignore_changes = [shm_size, ipc_mode, runtime, stop_signal, stop_timeout]
  }
}

data "docker_registry_image" "restic" {
  count = var.offsite_enabled ? 1 : 0
  name  = var.offsite.image
}

resource "docker_image" "restic" {
  count         = var.offsite_enabled ? 1 : 0
  name          = data.docker_registry_image.restic[0].name
  pull_triggers = [data.docker_registry_image.restic[0].sha256_digest]
  keep_locally  = true
}

resource "docker_container" "offsite" {
  count   = var.offsite_enabled ? 1 : 0
  name    = "${var.container_name}-offsite"
  image   = docker_image.restic[0].image_id
  restart = "unless-stopped"

  entrypoint = ["/bin/sh", "-c"]
  command = [<<-SCRIPT
    set -eu
    restic snapshots >/dev/null 2>&1 || restic init
    while :; do
      restic backup /backups --tag apollo-postgres
      restic forget --keep-last "$BACKUP_RETENTION_COUNT" --prune
      date -u '+%s' > /tmp/last-offsite-success
      sleep "$OFFSITE_INTERVAL_SECONDS"
    done
  SCRIPT
  ]

  env = [
    "RESTIC_REPOSITORY=${var.offsite.repository}",
    "RESTIC_PASSWORD=${var.offsite.restic_password}",
    "AWS_ACCESS_KEY_ID=${var.offsite.aws_access_key_id}",
    "AWS_SECRET_ACCESS_KEY=${var.offsite.aws_secret_key}",
    "BACKUP_RETENTION_COUNT=${var.schedule.retention_count}",
    "OFFSITE_INTERVAL_SECONDS=${var.offsite.interval_seconds}",
    "OFFSITE_MAX_AGE_SECONDS=${var.offsite.interval_seconds + 900}",
  ]

  volumes {
    volume_name    = docker_volume.backups.name
    container_path = "/backups"
    read_only      = true
  }
  read_only     = true
  security_opts = ["no-new-privileges:true"]
  tmpfs         = { "/tmp" = "rw,noexec,nosuid,nodev,size=16m,mode=1777" }
  capabilities { drop = ["ALL"] }
  log_driver = "local"
  log_opts   = { "max-size" = "10m", "max-file" = "3" }

  healthcheck {
    test         = ["CMD-SHELL", local.offsite_healthcheck_script]
    interval     = "60s"
    timeout      = "10s"
    retries      = 3
    start_period = "900s"
  }

  depends_on = [docker_container.backup]
}
