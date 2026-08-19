#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
vps="$repo_root/infra/lib/vps.sh"
remote="$repo_root/infra/programs/deploy-remote.sh"
bootstrap="$repo_root/infra/programs/bootstrap-vps.sh"

grep -q 'status --porcelain --untracked-files=all' "$vps"
grep -q 'ls-remote --exit-code origin refs/heads/main' "$vps"
grep -Fq "git -C \"\$repository\" archive \"\$commit\"" "$vps"
grep -Fq "release_stage=\"\$stage/staged/\$RELEASE_ID\"" "$vps"
grep -q 'active release ID .* cannot be reused' "$vps"
grep -Fq "cp \"\$COMPOSE_DIR/compose.yaml\" \"\$release_stage/compose.yaml\"" "$vps"
grep -Fq -- "-f \"\$release_root/compose.yaml\"" "$remote"
grep -Fq -- "-f \"/opt/apollo/staged/\$previous_release/compose.yaml\"" "$remote"
grep -Fq "APOLLO_SECRET_FILE=\"\$release_root/config/secrets.env\"" "$remote"
grep -q 'env -i PATH=' "$remote"
migration_line="$(grep -nF "\"\$release_root/programs/migrate.sh\" expand" "$remote" | cut -d: -f1 || true)"
pgbouncer_restart_line="$(grep -nF 'docker restart apollo-platform-pgbouncer' "$remote" | cut -d: -f1 || true)"
health_gate_line="$(grep -nF 'compose_run up -d --wait' "$remote" | cut -d: -f1 || true)"
[[ -n "$migration_line" && -n "$pgbouncer_restart_line" && -n "$health_gate_line" &&
  "$migration_line" -lt "$pgbouncer_restart_line" &&
  "$pgbouncer_restart_line" -lt "$health_gate_line" ]] || {
  echo 'FAIL: PgBouncer must restart after role migrations and before the health gate.' >&2
  exit 1
}
grep -q 'verify_runtime_identity' "$remote"
grep -q 'org.opencontainers.image.revision' "$remote"
grep -Fq "actual_image=\"\$(docker inspect" "$remote"
grep -Fq "rm -rf -- \"\$staged_path\"" "$remote"
grep -Fq "chmod 0711 \"\$stage/staged\" \"\$release_stage\"" "$vps"
grep -Fq "find \"\$release_stage/programs\" -type f -exec chmod 0555" "$vps"
grep -Fq "chmod 0444 \"\$release_stage/runtime/redis/users.acl\"" "$vps"
grep -Fq "\"\$stage/nginx/conf.d/20-production.conf\"" "$vps"
grep -Fq "chmod 0711 /opt/apollo /opt/apollo/staged \"\$target\"" "$vps"
grep -Fq "chmod 0444 \"\$target/runtime/redis/users.acl\"" "$vps"
grep -Fq 'install -d -m 0711 /opt/apollo /opt/apollo/staged' "$bootstrap"
if grep -Eq 'cp .*REPO_ROOT.*/(scripts/migrations|scripts/nginx|geoip)' "$vps"; then
  echo 'FAIL: production staging reads mutable service worktree content.' >&2
  exit 1
fi
echo 'Release staging-policy tests passed.'
