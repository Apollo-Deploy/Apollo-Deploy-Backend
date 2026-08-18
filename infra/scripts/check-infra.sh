#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
INFRA_DIR="$REPO_ROOT/infra"
TERRAFORM_DIR="$INFRA_DIR/terraform"
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/apollo-infra-check.XXXXXX")"
trap 'rm -rf -- "$work_dir"' EXIT

section() { printf '\n==> %s\n' "$1"; }
require() { command -v "$1" >/dev/null 2>&1 || {
  echo "Missing required tool: $1" >&2
  exit 127
}; }
for command_name in terraform docker jq shellcheck shfmt git python3; do require "$command_name"; done

section 'Rejecting tracked configuration, secrets, state, and plans'
if git -C "$REPO_ROOT" ls-files -z \
  | while IFS= read -r -d '' path; do
    case "$path" in
      infra/config/local.env | infra/config/local.secrets.env | infra/config/vps.env | infra/config/vps.secrets.env | \
        *.tfstate | *.tfstate.* | *.tfvars | *.tfvars.* | *backend.hcl | tfplan | *.tfplan | *.tfplan.*)
        printf '%s\n' "$path"
        ;;
    esac
  done | tee "$work_dir/tracked-sensitive" | grep -q .; then
  echo 'Tracked sensitive infrastructure artifacts are forbidden:' >&2
  cat "$work_dir/tracked-sensitive" >&2
  exit 1
fi

section 'Checking Terraform formatting and validation'
terraform fmt -check -recursive -diff "$TERRAFORM_DIR"
for root in bootstrap vps; do
  data_dir="$work_dir/tf-$root"
  mkdir -p "$data_dir"
  TF_DATA_DIR="$data_dir" terraform -chdir="$TERRAFORM_DIR/$root" init \
    -backend=false -input=false -lockfile=readonly -no-color >/dev/null
  TF_DATA_DIR="$data_dir" terraform -chdir="$TERRAFORM_DIR/$root" validate -no-color
done

section 'Validating Compose models'
runtime_fixture="$work_dir/runtime"
mkdir -p "$runtime_fixture/redis"
for runtime_file in \
  data.env pgbouncer.env redis.env platform.env signal.env billing.env backup.env offsite.env; do
  : >"$runtime_fixture/$runtime_file"
done
: >"$runtime_fixture/redis/users.acl"
common_env=(
  APOLLO_RUNTIME_DIR="$runtime_fixture"
  APOLLO_PROGRAM_DIR="$INFRA_DIR/programs"
  NGINX_CONFIG_DIR="$REPO_ROOT/apollo-platform-api/scripts/nginx"
  SIGNAL_GEOIP_DIR="$REPO_ROOT/apollo-signal-api/geoip"
  REPO_ROOT="$REPO_ROOT"
  NPMRC_PATH=/tmp/apollo-npmrc
  POSTGRES_IMAGE=postgres:test
  PGBOUNCER_IMAGE=pgbouncer:test
  REDIS_IMAGE=redis:test
  PLATFORM_IMAGE=platform:test
  SIGNAL_IMAGE=signal:test
  BILLING_IMAGE=billing:test
  NGINX_IMAGE=nginx:test
  CERTBOT_IMAGE=certbot:test
  RESTIC_IMAGE=restic:test
)
env "${common_env[@]}" docker compose --env-file /dev/null \
  -f "$INFRA_DIR/compose/compose.yaml" -f "$INFRA_DIR/compose/compose.local.yaml" \
  --profile signal --profile backup config --no-env-resolution --no-path-resolution -q
env "${common_env[@]}" APOLLO_RUNTIME_DIR=/opt/apollo/runtime APOLLO_PROGRAM_DIR=/opt/apollo/programs \
  NGINX_CONFIG_DIR=/opt/apollo/nginx SIGNAL_GEOIP_DIR=/opt/apollo/geoip \
  docker compose --env-file /dev/null \
  -f "$INFRA_DIR/compose/compose.yaml" \
  --profile signal --profile backup --profile tls config --no-env-resolution --no-path-resolution -q

section 'Running ShellCheck and shfmt'
shell_files=()
while IFS= read -r -d '' shell_file; do
  shell_files+=("$shell_file")
done < <(find "$INFRA_DIR" -type f -name '*.sh' -not -path '*/.terraform/*' -print0 | sort -z)
shellcheck -x -P SCRIPTDIR "${shell_files[@]}"
shfmt -d -i 2 -ci -bn "${shell_files[@]}"

section 'Validating JSON, migration manifest, and Python renderer'
jq -e '
  .schema_version == 1 and (.releases | type == "array") and
  ([.releases[].id] | length == (unique | length)) and
  all(.releases[]; .services | keys == ["billing", "platform", "signal"])
' "$INFRA_DIR/releases/approved-releases.json" >/dev/null
jq -e 'type == "array" and ([.[].key] | sort == ["billing", "platform", "signal"])' \
  "$INFRA_DIR/oauth-clients.json" >/dev/null
if [[ -n "$(find "$REPO_ROOT/apollo-platform-api/scripts/migrations" \
  "$REPO_ROOT/apollo-signal-api/scripts/migrations" \
  "$REPO_ROOT/apollo-billing-api/scripts/migrations" -type f -name '*.psql' -print -quit 2>/dev/null)" ]]; then
  bash "$SCRIPT_DIR/lib/validate-migration-phases.sh" "$REPO_ROOT" "$INFRA_DIR/migration-phases.tsv"
else
  awk -F '\t' '
    /^[[:space:]]*#/ || NF == 0 { next }
    NF != 3 || $1 !~ /^(platform|signal|billing)$/ || $2 !~ /^[A-Za-z0-9._-]+[.]psql$/ || $3 !~ /^(expand|contract)$/ { exit 1 }
    { key = $1 FS $2; if (seen[key]++) exit 1; count++ }
    END { if (count == 0) exit 1 }
  ' "$INFRA_DIR/migration-phases.tsv"
fi
PYTHONPYCACHEPREFIX="$work_dir/pycache" python3 -m py_compile "$INFRA_DIR/programs/render-oauth-sql.py"

section 'Running infrastructure regression tests'
while IFS= read -r test_file; do
  bash "$test_file"
done < <(find "$INFRA_DIR/tests" -type f -name '*-test.sh' -print | sort)

section 'Checking forbidden normal-operation patterns'
if rg -n 'docker compose down.*(-v|--volumes)|eval[[:space:]]|StrictHostKeyChecking=(no|accept-new)' \
  "$INFRA_DIR/apollo" "$INFRA_DIR/lib" "$INFRA_DIR/programs"; then
  echo 'A forbidden destructive, executable-config, or SSH trust pattern remains.' >&2
  exit 1
fi

section 'All infrastructure checks passed'
