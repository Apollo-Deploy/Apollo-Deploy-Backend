#!/usr/bin/env bash
# =============================================================================
# wait-healthy.sh — wait for a Docker container to report healthy status
#
# Environment variables:
#   CONTAINER     (required) — container name to inspect
#   MAX_ATTEMPTS  (default: 60) — max number of retries
#   INTERVAL      (default: 3) — seconds between retries
# =============================================================================
set -euo pipefail

CONTAINER="${CONTAINER:?ERROR: CONTAINER env var is required}"
MAX="${MAX_ATTEMPTS:-60}"
INTERVAL="${INTERVAL:-3}"

echo "==> Waiting for $CONTAINER to be healthy (max ${MAX} x ${INTERVAL}s)..."

for i in $(seq 1 "$MAX"); do
  STATUS=$(docker inspect --format='{{.State.Health.Status}}' "$CONTAINER" 2>/dev/null || echo "missing")
  if [ "$STATUS" = "healthy" ]; then
    echo "==> $CONTAINER is healthy."
    exit 0
  fi
  echo "    [$i/$MAX] $CONTAINER: $STATUS — waiting ${INTERVAL}s..."
  sleep "$INTERVAL"
done

echo "ERROR: $CONTAINER never became healthy after $((MAX * INTERVAL))s." >&2
docker logs --tail 20 "$CONTAINER" >&2 || true
exit 1
