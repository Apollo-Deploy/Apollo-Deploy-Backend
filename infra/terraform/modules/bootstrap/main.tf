# =============================================================================
# Bootstrap module — runs after containers are healthy:
#   1. Wait for Postgres to be healthy
#   2. Platform DB migrations
#   3. Signal DB + migrations (conditional on enable_signal)
#   4. Signal cross-DB grants (conditional)
#   5. Billing migrations
#   6. Wait for Platform API to be healthy
#   7. Register OAuth M2M clients (billing always; signal when enabled)
#   8. Read back OAuth credentials via external data sources
#
# All shell logic lives in scripts/ — no heredocs in this file.
# =============================================================================

# ── Step 1: Wait for Postgres ─────────────────────────────────────────────────
resource "terraform_data" "wait_postgres" {
  triggers_replace = [var.postgres_container, var.migration_trigger]

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = "CONTAINER='${var.postgres_container}' MAX_ATTEMPTS=60 INTERVAL=3 '${path.module}/scripts/wait-healthy.sh'"
  }
}

# ── Step 2: Platform migrations ───────────────────────────────────────────────
resource "terraform_data" "platform_migrations" {
  triggers_replace = [
    var.migration_trigger,
    sha1(join("", [
      for f in sort(fileset(var.platform_migrations_dir, "*.psql")) :
      filesha1("${var.platform_migrations_dir}/${f}")
    ])),
  ]

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = "'${path.module}/scripts/run-migrations.sh'"

    environment = {
      DB_CONTAINER             = var.postgres_container
      DB_PASS                  = var.db_password
      DB_USER                  = var.db_user
      DB_NAME                  = var.db_name
      MIGRATIONS_DIR           = var.platform_migrations_dir
      SERVICE                  = "platform"
      PLATFORM_APP_DB_PASS     = var.db_roles.platform_app
      BILLING_APP_DB_PASS      = var.db_roles.billing_app
      BILLING_SUPERUSER_DB_PASS = var.db_roles.billing_superuser
      SIGNAL_APP_DB_PASS       = var.db_roles.signal_app
      SIGNAL_SUPERUSER_DB_PASS = var.db_roles.signal_superuser
      PLATFORM_VERIFIER_DB_PASS = var.db_roles.platform_verifier
    }
  }

  depends_on = [terraform_data.wait_postgres]
}

# ── Step 3: Signal DB + migrations (conditional) ──────────────────────────────
resource "terraform_data" "signal_migrations" {
  triggers_replace = [
    var.migration_trigger,
    var.enable_signal,
    sha1(join("", [
      for f in sort(fileset(var.signal_migrations_dir, "*.psql")) :
      filesha1("${var.signal_migrations_dir}/${f}")
    ])),
  ]

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = var.enable_signal ? "'${path.module}/scripts/run-migrations.sh'" : "echo '==> [signal] Skipped (enable_signal=false)'"

    environment = var.enable_signal ? {
      DB_CONTAINER   = var.postgres_container
      DB_PASS        = var.db_password
      DB_USER        = var.db_user
      DB_NAME        = var.signal_db_name
      MIGRATIONS_DIR = var.signal_migrations_dir
      SERVICE        = "signal"
    } : {}
  }

  depends_on = [terraform_data.platform_migrations]
}

# ── Step 4: Signal cross-DB grants (conditional) ──────────────────────────────
resource "terraform_data" "signal_grants" {
  triggers_replace = [var.migration_trigger, var.enable_signal]

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-BASH
      set -euo pipefail
      ENABLED="${var.enable_signal}"
      GRANTS_FILE="${var.platform_migrations_dir}/39b_signal_grants.psql"

      if [ "$ENABLED" != "true" ]; then
        echo "==> [signal grants] Skipped (enable_signal=false)"
        exit 0
      fi

      if [ ! -f "$GRANTS_FILE" ]; then
        echo "==> [signal grants] No 39b_signal_grants.psql found — skipping."
        exit 0
      fi

      echo "==> [signal grants] Applying cross-DB grants..."
      docker exec -i -e PGPASSWORD="${var.db_password}" "${var.postgres_container}" \
        psql -U "${var.db_user}" -d "${var.signal_db_name}" -v ON_ERROR_STOP=1 \
        < "$GRANTS_FILE"
      echo "==> [signal grants] Done."
    BASH
  }

  depends_on = [terraform_data.signal_migrations]
}

# ── Step 5: Billing migrations ────────────────────────────────────────────────
resource "terraform_data" "billing_migrations" {
  triggers_replace = [
    var.migration_trigger,
    sha1(join("", [
      for f in sort(fileset(var.billing_migrations_dir, "*.psql")) :
      filesha1("${var.billing_migrations_dir}/${f}")
    ])),
  ]

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = "'${path.module}/scripts/run-migrations.sh'"

    environment = {
      DB_CONTAINER   = var.postgres_container
      DB_PASS        = var.db_password
      DB_USER        = var.db_user
      DB_NAME        = var.db_name
      MIGRATIONS_DIR = var.billing_migrations_dir
      SERVICE        = "billing"
    }
  }

  depends_on = [terraform_data.signal_grants]
}

# ── Step 6: Wait for Platform API ─────────────────────────────────────────────
resource "terraform_data" "wait_platform_api" {
  triggers_replace = [var.platform_container, var.migration_trigger]

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = "CONTAINER='${var.platform_container}' MAX_ATTEMPTS=80 INTERVAL=5 '${path.module}/scripts/wait-healthy.sh'"
  }

  depends_on = [terraform_data.billing_migrations]
}

# ── Step 7: Register OAuth M2M clients ────────────────────────────────────────
resource "terraform_data" "register_oauth_clients" {
  triggers_replace = [
    var.migration_trigger,
    var.enable_signal,
    filesha1(var.oauth_clients_json_path),
  ]

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = "'${path.module}/scripts/register-oauth.sh'"

    environment = {
      PLATFORM_DIR  = var.platform_api_dir
      CLIENTS_JSON  = var.oauth_clients_json_path
      DB_PASSWORD   = var.db_password
      ENABLE_SIGNAL = tostring(var.enable_signal)
    }
  }

  depends_on = [terraform_data.wait_platform_api]
}

# ── Step 8: Read back OAuth credentials ───────────────────────────────────────
data "external" "billing_oauth" {
  program = ["/bin/bash", "${path.module}/scripts/read-env-values.sh"]
  query = {
    env_file = "${var.billing_api_dir}/.env"
    keys     = "PLATFORM_CLIENT_ID,PLATFORM_CLIENT_SECRET"
  }
  depends_on = [terraform_data.register_oauth_clients]
}

data "external" "signal_oauth" {
  program = ["/bin/bash", "${path.module}/scripts/read-env-values.sh"]
  query = {
    env_file = "${var.signal_api_dir}/.env"
    keys     = "PLATFORM_CLIENT_ID,PLATFORM_CLIENT_SECRET"
  }
  depends_on = [terraform_data.register_oauth_clients]
}

data "external" "platform_oauth_ids" {
  program = ["/bin/bash", "${path.module}/scripts/read-env-values.sh"]
  query = {
    env_file = "${var.platform_api_dir}/.env"
    keys     = "OAUTH_TRUSTED_CLIENT_IDS,OAUTH_SERVICE_CLIENT_IDS"
  }
  depends_on = [terraform_data.register_oauth_clients]
}
