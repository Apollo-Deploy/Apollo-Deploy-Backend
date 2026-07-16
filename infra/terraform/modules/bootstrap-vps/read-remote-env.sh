#!/usr/bin/env bash
# =============================================================================
# read-remote-env.sh — Terraform external data source helper (VPS variant)
#
# Reads specified keys from a remote .env file over SSH and outputs JSON.
#
# Input (from Terraform external data source "query" map):
#   ssh_cmd   — full SSH command prefix (e.g. "ssh -p 22 -i ~/.ssh/id ... user@host")
#   env_path  — remote path to the .env file
#   keys      — comma-separated list of variable names to extract
#
# Output: JSON object with each key → value
# =============================================================================

set -euo pipefail

QUERY=$(cat)
SSH_CMD=$(echo "$QUERY" | python3 -c "import sys,json; print(json.load(sys.stdin)['ssh_cmd'])")
ENV_PATH=$(echo "$QUERY" | python3 -c "import sys,json; print(json.load(sys.stdin)['env_path'])")
KEYS=$(echo "$QUERY"    | python3 -c "import sys,json; print(json.load(sys.stdin)['keys'])")

# Fetch the remote .env file content
CONTENT=""
if CONTENT=$($SSH_CMD "cat '$ENV_PATH' 2>/dev/null" 2>/dev/null); then
  : # success
fi

# Build output JSON
OUTPUT="{"
FIRST=1
IFS=',' read -ra KEY_LIST <<< "$KEYS"
for key in "${KEY_LIST[@]}"; do
  key=$(echo "$key" | tr -d '[:space:]')

  value=""
  if [ -n "$CONTENT" ]; then
    value=$(echo "$CONTENT" | grep "^${key}=" | head -1 | cut -d'=' -f2- | tr -d '"' | tr -d "'" || true)
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
