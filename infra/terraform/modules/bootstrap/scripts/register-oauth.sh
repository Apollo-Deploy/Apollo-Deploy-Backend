#!/usr/bin/env bash
# =============================================================================
# register-oauth.sh — register OAuth M2M clients headlessly via bun
#
# Environment variables (injected by Terraform local-exec):
#   PLATFORM_DIR    (required) — absolute path to apollo-platform-api directory
#   CLIENTS_JSON    (required) — absolute path to the oauth-clients.json file
#   DB_PASSWORD     (required) — postgres superuser password (Terraform-generated)
#   REDIS_PASSWORD  (required) — redis password (Terraform-generated)
#   ENABLE_SIGNAL   (default: true) — if "false", filters out the signal client
#
# This script runs on the HOST machine, not inside Docker.
# The platform .env uses Docker service names (postgres, redis) which only
# resolve inside the apollo network. We capture the Terraform-provided secrets
# BEFORE sourcing .env so the source cannot overwrite them.
# =============================================================================
set -euo pipefail

PLATFORM_DIR="${PLATFORM_DIR:?ERROR: PLATFORM_DIR is required}"
CLIENTS_JSON="${CLIENTS_JSON:?ERROR: CLIENTS_JSON is required}"
ENABLE_SIGNAL="${ENABLE_SIGNAL:-true}"

# ── Capture Terraform-provided credentials BEFORE sourcing .env ───────────────
# If we source .env first it would clobber these with stale values.
_TF_DB_PASSWORD="${DB_PASSWORD:?ERROR: DB_PASSWORD is required}"
_TF_REDIS_PASSWORD="${REDIS_PASSWORD:?ERROR: REDIS_PASSWORD is required}"

ACTIVE_JSON="${CLIENTS_JSON}.active"

echo "==> [oauth] Preparing clients list (enable_signal=$ENABLE_SIGNAL)..."

if [ "$ENABLE_SIGNAL" = "true" ]; then
  cp "$CLIENTS_JSON" "$ACTIVE_JSON"
  echo "==> [oauth] Registering: billing + signal"
else
  python3 -c "
import json
clients = json.load(open('$CLIENTS_JSON'))
filtered = [c for c in clients if c.get('key') != 'signal']
json.dump(filtered, open('$ACTIVE_JSON', 'w'), indent=2)
print('  Filtered to:', [c['key'] for c in filtered])
"
  echo "==> [oauth] Registering: billing only"
fi

cd "$PLATFORM_DIR"

# Ensure a .env exists so bun can start without missing-file errors
if [ ! -f .env ]; then
  echo "==> [oauth] No .env found — creating minimal stub"
  touch .env
fi

# Source .env for non-credential config (PLATFORM_URL, auth settings, KMS, etc.)
# We deliberately allow it to overwrite the shell env — we will restore credentials below.
set -a
# shellcheck disable=SC1091
source .env 2>/dev/null || true
set +a

# ── Always override with host-reachable values and Terraform credentials ──────
# These MUST come after source .env so they win regardless of .env contents.
export DB_HOST=localhost
export DB_PORT="${DB_PORT:-5432}"
export DB_USER="${DB_USER:-postgres}"
export DB_PASSWORD="$_TF_DB_PASSWORD"
export DB_NAME="${DB_NAME:-apollo_deploy_platform}"
export DB_SSL_ENABLED=false

export REDIS_HOST=localhost
export REDIS_PORT="${REDIS_PORT:-6379}"
export REDIS_PASSWORD="$_TF_REDIS_PASSWORD"
export REDIS_TLS=false

echo "==> [oauth] Connecting to DB at ${DB_HOST}:${DB_PORT}/${DB_NAME}"
echo "==> [oauth] Connecting to Redis at ${REDIS_HOST}:${REDIS_PORT}"
echo "==> [oauth] Running register-oauth-clients..."

bun run oauth:register-clients --clients "$ACTIVE_JSON"

echo "==> [oauth] OAuth M2M clients registered successfully."
