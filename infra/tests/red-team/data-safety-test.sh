#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
compose="$repo_root/infra/compose/compose.yaml"
for volume in postgres-data redis-data letsencrypt-certs certbot-webroot postgres-backups; do
  awk -v wanted="$volume:" '
    $0 == "  " wanted { in_volume = 1; next }
    in_volume && $0 ~ /^  [A-Za-z0-9_-]+:/ { exit }
    in_volume && $0 ~ /external: true/ { found = 1 }
    END { exit !found }
  ' "$compose" || {
    echo "FAIL: $volume is not external" >&2
    exit 1
  }
done
if rg -n 'docker compose down.*(-v|--volumes)' \
  "$repo_root/infra/apollo" "$repo_root/infra/lib" "$repo_root/infra/programs"; then
  echo 'FAIL: normal automation can remove Compose volumes.' >&2
  exit 1
fi
grep -q 'from = module.deployment' "$repo_root/infra/terraform/vps/migrations.tf"
grep -q 'destroy = false' "$repo_root/infra/terraform/vps/migrations.tf"
echo 'Persistent-data safety tests passed.'
