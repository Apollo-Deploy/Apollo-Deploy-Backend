#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
fixture="$(mktemp -d "${TMPDIR:-/tmp}/apollo-config-test.XXXXXX")"
trap 'rm -rf -- "$fixture"' EXIT
CONFIG_DIR="$fixture/config"
mkdir -p "$CONFIG_DIR"
# shellcheck source=../../lib/common.sh
source "$repo_root/infra/lib/common.sh"
# shellcheck source=../../lib/config.sh
source "$repo_root/infra/lib/config.sh"

cp "$repo_root/infra/config/local.env.example" "$CONFIG_DIR/local.env"
generate_secret_file | write_protected_file "$CONFIG_DIR/local.secrets.env"
chmod 600 "$CONFIG_DIR/local.env"
for key in SIGNAL_WEBHOOK_SECRET_KEY SIGNAL_IMPORT_CREDENTIALS_KEY; do
  value="$(env_value "$CONFIG_DIR/local.secrets.env" "$key")"
  APOLLO_TEST_BASE64="$value" python3 - <<'PY'
import base64
import os

assert len(base64.b64decode(os.environ["APOLLO_TEST_BASE64"], validate=True)) == 32
PY
done
render_runtime local "$CONFIG_DIR/local.env" "$CONFIG_DIR/local.secrets.env" '' "$fixture/runtime"
for file in "$fixture/runtime"/*.env "$fixture/runtime/redis/users.acl"; do
  [[ "$(portable_mode "$file")" == 600 ]] || {
    echo "FAIL: unsafe mode on $file" >&2
    exit 1
  }
done
grep -q '^NODE_ENV=development$' "$fixture/runtime/platform.env"
grep -q '^APOLLO_SIGNAL_ENV=development$' "$fixture/runtime/signal.env"
grep -q '^user default on #[0-9a-f]\{64\} ' "$fixture/runtime/redis/users.acl"

{
  printf 'AWS_ACCESS_KEY_ID=terraform-access-key\n'
  printf 'AWS_SECRET_ACCESS_KEY=terraform-secret-key\n'
  printf 'AWS_ACCOUNT_ID=123456789012\n'
} | write_protected_file "$fixture/aws.env"
render_runtime vps "$CONFIG_DIR/local.env" "$CONFIG_DIR/local.secrets.env" \
  "$fixture/aws.env" "$fixture/vps-runtime"
grep -q '^APOLLO_SIGNAL_AWS_ACCESS_KEY_ID=terraform-access-key$' "$fixture/vps-runtime/signal.env"
grep -q '^APOLLO_SIGNAL_AWS_SECRET_ACCESS_KEY=terraform-secret-key$' "$fixture/vps-runtime/signal.env"

CONFIG_DIR="$fixture/unsafe-config"
mkdir -p "$CONFIG_DIR"
write_protected_file "$CONFIG_DIR/local.env" <"$repo_root/infra/config/local.env.example"
ln -s "$fixture/symlink-target" "$CONFIG_DIR/local.secrets.env"
if (ensure_local_config >/dev/null 2>&1); then
  echo 'FAIL: local config accepted a secret-file symlink.' >&2
  exit 1
fi
[[ ! -e "$fixture/symlink-target" ]]

write_protected_file "$fixture/placeholders.env" <"$repo_root/infra/config/secrets.env.example"
if (validate_secret_contract "$fixture/placeholders.env" vps >/dev/null 2>&1); then
  echo 'FAIL: production secret contract accepted public placeholders.' >&2
  exit 1
fi
echo 'Configuration rendering tests passed.'
