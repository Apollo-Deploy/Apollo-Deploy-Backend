# =============================================================================
# Bootstrap VPS module — runs migrations and OAuth M2M setup on the remote VPS.
#
# Uses local-exec + SSH (not remote-exec) so we don't need a null_resource
# provider. Migrations are piped from local .psql files directly into the
# remote postgres container via ssh + docker exec.
#
# Flow:
#   1. Wait for Postgres to be healthy
#   2. Upload migration files
#   3. Run platform migrations (including DB role creation)
#   4. Create signal DB + run signal migrations
#   5. Apply signal grants (39b)
#   6. Run billing migrations
#   7. Wait for platform API to be healthy
#   8. Upload oauth-clients.json + run headless OAuth registration
#   9. Read back OAuth credentials from VPS .env files
# =============================================================================

locals {
  ssh = "ssh -p ${var.vps_ssh_port} -i ${var.vps_ssh_key_path} -o StrictHostKeyChecking=no ${var.vps_user}@${var.vps_host}"
}

# ── Step 1: Wait for Postgres ─────────────────────────────────────────────────
resource "terraform_data" "wait_postgres" {
  triggers_replace = [var.migration_trigger]

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-BASH
      echo "==> [VPS] Waiting for ${var.postgres_container}..."
      for i in $(seq 1 60); do
        STATUS=$(${local.ssh} "docker inspect --format='{{.State.Health.Status}}' ${var.postgres_container} 2>/dev/null || echo missing")
        if [ "$STATUS" = "healthy" ]; then
          echo "==> [VPS] ${var.postgres_container} is healthy."
          exit 0
        fi
        echo "    Status: $STATUS (attempt $i/60)..."
        sleep 3
      done
      echo "ERROR: ${var.postgres_container} never became healthy." >&2
      exit 1
    BASH
  }
}

# ── Step 2: Upload migration files to VPS ────────────────────────────────────
resource "terraform_data" "upload_migrations" {
  triggers_replace = [
    var.migration_trigger,
    sha1(join("", [
      for f in sort(fileset(var.platform_migrations_source_dir, "*.psql")) :
      filesha1("${var.platform_migrations_source_dir}/${f}")
    ])),
    sha1(join("", [
      for f in sort(fileset(var.signal_migrations_source_dir, "*.psql")) :
      filesha1("${var.signal_migrations_source_dir}/${f}")
    ])),
    sha1(join("", [
      for f in sort(fileset(var.billing_migrations_source_dir, "*.psql")) :
      filesha1("${var.billing_migrations_source_dir}/${f}")
    ])),
  ]

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-BASH
      set -euo pipefail
      SCP="scp -P ${var.vps_ssh_port} -i ${var.vps_ssh_key_path} -o StrictHostKeyChecking=no"

      ${local.ssh} "mkdir -p /opt/apollo/migrations/{platform,signal,billing}"

      echo "==> [VPS] Uploading platform migrations..."
      $SCP ${var.platform_migrations_source_dir}/*.psql \
        ${var.vps_user}@${var.vps_host}:/opt/apollo/migrations/platform/

      echo "==> [VPS] Uploading signal migrations..."
      if ls ${var.signal_migrations_source_dir}/*.psql 2>/dev/null | head -1 | grep -q psql; then
        $SCP ${var.signal_migrations_source_dir}/*.psql \
          ${var.vps_user}@${var.vps_host}:/opt/apollo/migrations/signal/
      fi

      echo "==> [VPS] Uploading billing migrations..."
      if ls ${var.billing_migrations_source_dir}/*.psql 2>/dev/null | head -1 | grep -q psql; then
        $SCP ${var.billing_migrations_source_dir}/*.psql \
          ${var.vps_user}@${var.vps_host}:/opt/apollo/migrations/billing/
      fi
    BASH
  }

  depends_on = [terraform_data.wait_postgres]
}

# ── Step 3: Platform migrations ───────────────────────────────────────────────
resource "terraform_data" "platform_migrations" {
  triggers_replace = [terraform_data.upload_migrations.id]

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-BASH
      set -euo pipefail

      ${local.ssh} bash <<'REMOTE'
      set -euo pipefail
      PG="${var.postgres_container}"
      PASS="${var.db_password}"
      DB="${var.db_name}"
      USER="${var.db_user}"

      # Ensure platform DB exists
      docker exec -e PGPASSWORD="$PASS" "$PG" \
        psql -U "$USER" -d postgres -tc "SELECT 1 FROM pg_database WHERE datname='$DB'" | grep -q 1 \
        || docker exec -e PGPASSWORD="$PASS" "$PG" \
             psql -U "$USER" -d postgres -c "CREATE DATABASE \"$DB\""

      for f in $(ls /opt/apollo/migrations/platform/*.psql | sort); do
        filename=$(basename "$f")
        echo "  ==> Applying platform migration: $filename"

        if [ "$filename" = "39_db_roles.psql" ]; then
          {
            printf "\\\\set platform_password '%s'\n"      "${var.platform_app_db_pass}"
            printf "\\\\set billing_password '%s'\n"       "${var.billing_app_db_pass}"
            printf "\\\\set billing_super_password '%s'\n" "${var.billing_superuser_db_pass}"
            printf "\\\\set signal_password '%s'\n"        "${var.signal_app_db_pass}"
            printf "\\\\set signal_super_password '%s'\n"  "${var.signal_superuser_db_pass}"
            printf "\\\\set verifier_password '%s'\n"      "${var.platform_verifier_db_pass}"
            cat "$f"
          } | docker exec -i -e PGPASSWORD="$PASS" "$PG" \
              psql -U "$USER" -d "$DB" -v ON_ERROR_STOP=1
        else
          docker exec -i -e PGPASSWORD="$PASS" "$PG" \
            psql -U "$USER" -d "$DB" -v ON_ERROR_STOP=1 < "$f"
        fi
      done
      echo "==> Platform migrations complete."
      REMOTE
    BASH
  }

  depends_on = [terraform_data.upload_migrations]
}

# ── Step 4: Signal DB + migrations ───────────────────────────────────────────
resource "terraform_data" "signal_migrations" {
  triggers_replace = [terraform_data.upload_migrations.id]

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-BASH
      ${local.ssh} bash <<'REMOTE'
      set -euo pipefail
      PG="${var.postgres_container}"
      PASS="${var.db_password}"
      SIGNAL_DB="${var.signal_db_name}"
      USER="${var.db_user}"

      docker exec -e PGPASSWORD="$PASS" "$PG" \
        psql -U "$USER" -d postgres -tc "SELECT 1 FROM pg_database WHERE datname='$SIGNAL_DB'" | grep -q 1 \
        || docker exec -e PGPASSWORD="$PASS" "$PG" \
             psql -U "$USER" -d postgres -c "CREATE DATABASE \"$SIGNAL_DB\""

      docker exec -e PGPASSWORD="$PASS" "$PG" \
        psql -U "$USER" -d "$SIGNAL_DB" -c "
          CREATE TABLE IF NOT EXISTS _signal_migration_history (
            filename TEXT PRIMARY KEY, checksum TEXT NOT NULL,
            applied_at TIMESTAMPTZ NOT NULL DEFAULT now());"

      for f in $(ls /opt/apollo/migrations/signal/*.psql 2>/dev/null | sort); do
        filename=$(basename "$f")
        checksum=$(sha256sum "$f" | cut -d' ' -f1)
        existing=$(docker exec -e PGPASSWORD="$PASS" "$PG" \
          psql -U "$USER" -d "$SIGNAL_DB" -tAc \
          "SELECT checksum FROM _signal_migration_history WHERE filename='$filename'" 2>/dev/null | tr -d '[:space:]')
        [ -n "$existing" ] && [ "$existing" = "$checksum" ] && continue
        echo "  ==> Applying signal migration: $filename"
        docker exec -i -e PGPASSWORD="$PASS" "$PG" \
          psql -U "$USER" -d "$SIGNAL_DB" -v ON_ERROR_STOP=1 < "$f"
        docker exec -e PGPASSWORD="$PASS" "$PG" \
          psql -U "$USER" -d "$SIGNAL_DB" -c \
          "INSERT INTO _signal_migration_history (filename,checksum) VALUES ('$filename','$checksum')
           ON CONFLICT (filename) DO UPDATE SET checksum=EXCLUDED.checksum, applied_at=now()"
      done
      echo "==> Signal migrations complete."
      REMOTE
    BASH
  }

  depends_on = [terraform_data.platform_migrations]
}

# ── Step 4b: Signal grants ────────────────────────────────────────────────────
resource "terraform_data" "signal_grants" {
  triggers_replace = [terraform_data.signal_migrations.id]

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-BASH
      GRANTS=$(${local.ssh} "cat /opt/apollo/migrations/platform/39b_signal_grants.psql 2>/dev/null || true")
      if [ -z "$GRANTS" ]; then
        echo "==> [VPS] No 39b_signal_grants.psql — skipping."
        exit 0
      fi
      ${local.ssh} bash <<'REMOTE'
      docker exec -i \
        -e PGPASSWORD="${var.db_password}" "${var.postgres_container}" \
        psql -U "${var.db_user}" -d "${var.signal_db_name}" -v ON_ERROR_STOP=1 \
        < /opt/apollo/migrations/platform/39b_signal_grants.psql
      echo "==> Signal grants applied."
      REMOTE
    BASH
  }

  depends_on = [terraform_data.signal_migrations]
}

# ── Step 5: Billing migrations ────────────────────────────────────────────────
resource "terraform_data" "billing_migrations" {
  triggers_replace = [terraform_data.upload_migrations.id]

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-BASH
      ${local.ssh} bash <<'REMOTE'
      set -euo pipefail
      PG="${var.postgres_container}"
      PASS="${var.db_password}"
      DB="${var.db_name}"
      USER="${var.db_user}"

      docker exec -e PGPASSWORD="$PASS" "$PG" \
        psql -U "$USER" -d "$DB" -c "
          CREATE TABLE IF NOT EXISTS _billing_migration_history (
            filename TEXT PRIMARY KEY, checksum TEXT NOT NULL,
            applied_at TIMESTAMPTZ NOT NULL DEFAULT now());"

      for f in $(ls /opt/apollo/migrations/billing/*.psql 2>/dev/null | sort); do
        filename=$(basename "$f")
        checksum=$(sha256sum "$f" | cut -d' ' -f1)
        existing=$(docker exec -e PGPASSWORD="$PASS" "$PG" \
          psql -U "$USER" -d "$DB" -tAc \
          "SELECT checksum FROM _billing_migration_history WHERE filename='$filename'" 2>/dev/null | tr -d '[:space:]')
        [ -n "$existing" ] && [ "$existing" = "$checksum" ] && continue
        echo "  ==> Applying billing migration: $filename"
        docker exec -i -e PGPASSWORD="$PASS" "$PG" \
          psql -U "$USER" -d "$DB" -v ON_ERROR_STOP=1 < "$f"
        docker exec -e PGPASSWORD="$PASS" "$PG" \
          psql -U "$USER" -d "$DB" -c \
          "INSERT INTO _billing_migration_history (filename,checksum) VALUES ('$filename','$checksum')
           ON CONFLICT (filename) DO UPDATE SET checksum=EXCLUDED.checksum, applied_at=now()"
      done
      echo "==> Billing migrations complete."
      REMOTE
    BASH
  }

  depends_on = [terraform_data.signal_grants]
}

# ── Step 6: Wait for Platform API ────────────────────────────────────────────
resource "terraform_data" "wait_platform_api" {
  triggers_replace = [terraform_data.billing_migrations.id]

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-BASH
      echo "==> [VPS] Waiting for ${var.platform_container}..."
      for i in $(seq 1 80); do
        STATUS=$(${local.ssh} "docker inspect --format='{{.State.Health.Status}}' ${var.platform_container} 2>/dev/null || echo missing")
        if [ "$STATUS" = "healthy" ]; then
          echo "==> [VPS] ${var.platform_container} is healthy."
          exit 0
        fi
        echo "    Status: $STATUS (attempt $i/80)..."
        sleep 5
      done
      echo "ERROR: ${var.platform_container} never became healthy." >&2
      exit 1
    BASH
  }

  depends_on = [terraform_data.billing_migrations]
}

# ── Step 7: Upload oauth-clients.json and register M2M clients ───────────────
resource "terraform_data" "register_oauth_clients" {
  triggers_replace = [
    var.migration_trigger,
    sha1(var.oauth_clients_json),
  ]

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-BASH
      set -euo pipefail
      SCP="scp -P ${var.vps_ssh_port} -i ${var.vps_ssh_key_path} -o StrictHostKeyChecking=no"

      # Write the oauth-clients.json to a temp file and upload it
      TMP=$(mktemp /tmp/oauth-clients-XXXX.json)
      cat > "$TMP" << 'OAUTHEOF'
${var.oauth_clients_json}
OAUTHEOF
      $SCP "$TMP" ${var.vps_user}@${var.vps_host}:/opt/apollo/oauth-clients.json
      rm "$TMP"

      # Run headless registration inside the platform container
      ${local.ssh} bash <<'REMOTE'
      set -euo pipefail
      echo "==> [VPS] Registering OAuth M2M clients..."

      docker exec apollo-platform \
        bun run oauth:register-clients --clients /opt/apollo/oauth-clients.json \
        || {
          # The container /opt/apollo path may not exist; try volume mount approach
          docker cp /opt/apollo/oauth-clients.json apollo-platform:/tmp/oauth-clients.json
          docker exec apollo-platform \
            bun run oauth:register-clients --clients /tmp/oauth-clients.json
        }

      echo "==> [VPS] OAuth clients registered."
      REMOTE
    BASH
  }

  depends_on = [terraform_data.wait_platform_api]
}

# ── Step 8: Read back OAuth credentials from VPS .env files ──────────────────
# SSH into the VPS, cat each service's .env, extract the values, return JSON.
data "external" "signal_oauth" {
  program = ["/bin/bash", "${path.module}/read-remote-env.sh"]

  query = {
    ssh_cmd  = local.ssh
    env_path = "/opt/apollo/signal/.env"
    keys     = "PLATFORM_CLIENT_ID,PLATFORM_CLIENT_SECRET"
  }

  depends_on = [terraform_data.register_oauth_clients]
}

data "external" "billing_oauth" {
  program = ["/bin/bash", "${path.module}/read-remote-env.sh"]

  query = {
    ssh_cmd  = local.ssh
    env_path = "/opt/apollo/billing/.env"
    keys     = "PLATFORM_CLIENT_ID,PLATFORM_CLIENT_SECRET"
  }

  depends_on = [terraform_data.register_oauth_clients]
}

data "external" "platform_oauth_ids" {
  program = ["/bin/bash", "${path.module}/read-remote-env.sh"]

  query = {
    ssh_cmd  = local.ssh
    env_path = "/opt/apollo/platform/.env"
    keys     = "OAUTH_TRUSTED_CLIENT_IDS,OAUTH_SERVICE_CLIENT_IDS"
  }

  depends_on = [terraform_data.register_oauth_clients]
}
