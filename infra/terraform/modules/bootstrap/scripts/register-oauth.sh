#!/usr/bin/env bash
# =============================================================================
# register-oauth.sh — register OAuth M2M clients headlessly via bun
#
# Environment variables:
#   PLATFORM_DIR    (required) — absolute path to apollo-platform-api directory
#   CLIENTS_JSON    (required) — absolute path to the oauth-clients.json file
#   DB_PASSWORD     (required) — postgres password for the bun process
#   ENABLE_SIGNAL   (default: true) — if false, filters out the signal client
# =============================================================================
set -euo pipefail

PLATFORM_DIR="${PLATFORM_DIR:?ERROR: PLATFORM_DIR is required}"
CLIENTS_JSON="${CLIENTS_JSON:?ERROR: CLIENTS_JSON is required}"
DB_PASSWORD="${DB_PASSWORD:?ERROR: DB_PASSWORD is required}"
ENABLE_SIGNAL="${ENABLE_SIGNAL:-true}"

ACTIVE_JSON="${CLIENTS_JSON}.active"

echo "==> [oauth] Preparing clients list (enable_signal=$ENABLE_SIGNAL)..."

if [ "$ENABLE_SIGNAL" = "true" ]; then
  cp "$CLIENTS_JSON" "$ACTIVE_JSON"
  echo "==> [oauth] Registering: billing + signal"
else
  python3 -c "
import json, sys
clients = json.load(open('$CLIENTS_JSON'))
filtered = [c for c in clients if c.get('key') != 'signal']
json.dump(filtered, open('$ACTIVE_JSON', 'w'), indent=2)
print('  Filtered to:', [c['key'] for c in filtered])
"
  echo "==> [oauth] Registering: billing only"
fi

cd "$PLATFORM_DIR"

# Ensure a .env file exists so bun can resolve DB connection
if [ ! -f .env ]; then
  echo "WARNING: .env not found in platform dir — creating minimal stub"
  cat > .env << 'ENVEOF'
DB_HOST=localhost
DB_PORT=5432
DB_USER=postgres
DB_NAME=apollo_deploy_platform
ENVEOF
fi

# Load .env (non-secret values), then force DB_PASSWORD
set -a
# shellcheck disable=SC1091
source .env 2>/dev/null || true
set +a
export DB_PASSWORD="$DB_PASSWORD"

echo "==> [oauth] Running register-oauth-clients..."
bun run oauth:register-clients --clients "$ACTIVE_JSON"
echo "==> [oauth] OAuth M2M clients registered successfully."
