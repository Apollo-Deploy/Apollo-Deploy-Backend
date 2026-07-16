#!/usr/bin/env bash
# =============================================================================
# read-env-values.sh — Terraform external data source helper
#
# Reads specified keys from a .env file and outputs them as JSON.
# Used by the bootstrap module to surface OAuth credentials written by
# register-oauth-clients back into Terraform state.
#
# Input (from Terraform external data source "query" map — read from stdin):
#   env_file  — path to the .env file to read
#   keys      — comma-separated list of variable names to extract
#
# Output: JSON object { key: value, ... } (empty string if key is missing)
# =============================================================================
set -euo pipefail

QUERY=$(cat)
ENV_FILE=$(echo "$QUERY" | python3 -c "import sys,json; print(json.load(sys.stdin)['env_file'])")
KEYS=$(echo "$QUERY"    | python3 -c "import sys,json; print(json.load(sys.stdin)['keys'])")

OUTPUT="{"
FIRST=1
IFS=',' read -ra KEY_LIST <<< "$KEYS"

for key in "${KEY_LIST[@]}"; do
  key=$(echo "$key" | tr -d '[:space:]')

  value=""
  if [ -f "$ENV_FILE" ]; then
    value=$(grep "^${key}=" "$ENV_FILE" 2>/dev/null | head -1 | cut -d'=' -f2- | tr -d '"' | tr -d "'" || true)
  fi

  escaped=$(python3 -c "import json,sys; print(json.dumps(sys.argv[1]))" "$value" | tr -d '"')

  if [ "$FIRST" -eq 1 ]; then
    FIRST=0
  else
    OUTPUT="${OUTPUT},"
  fi
  OUTPUT="${OUTPUT}\"${key}\":\"${escaped}\""
done

OUTPUT="${OUTPUT}}"
echo "$OUTPUT"
