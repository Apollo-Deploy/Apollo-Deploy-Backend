#!/usr/bin/env bash
set -euo pipefail

PROGRAM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APOLLO_ROOT="$(cd "$PROGRAM_DIR/.." && pwd)"
# shellcheck source=../lib/common.sh
source "$APOLLO_ROOT/lib/common.sh"

secret_file="${APOLLO_SECRET_FILE:-$APOLLO_ROOT/config/secrets.env}"
definitions="${APOLLO_OAUTH_DEFINITIONS:-$APOLLO_ROOT/oauth-clients.json}"
renderer="${APOLLO_OAUTH_RENDERER:-$PROGRAM_DIR/render-oauth-sql.py}"
psql_runner="${APOLLO_PSQL_RUNNER:-$APOLLO_ROOT/scripts/lib/run-psql-stdin.sh}"
base_domain="${APOLLO_BASE_DOMAIN:-apollodeploy.com}"

require_protected_file "$secret_file" 'Apollo secrets'
validate_env_file "$secret_file"
for file in "$definitions" "$renderer" "$psql_runner"; do
  [[ -f "$file" && ! -L "$file" ]] || die "OAuth artifact is unavailable or unsafe: $file"
done

oauth_json="$({
  jq -c '.[]' "$definitions" | while IFS= read -r definition; do
    key="$(jq -r '.key' <<<"$definition")"
    upper="$(printf '%s' "$key" | tr '[:lower:]' '[:upper:]')"
    client_id="$(env_value "$secret_file" "${upper}_OAUTH_CLIENT_ID")"
    client_secret="$(env_value "$secret_file" "${upper}_OAUTH_CLIENT_SECRET")"
    record_id="$(env_value "$secret_file" "${upper}_OAUTH_RECORD_ID")"
    export APOLLO_OAUTH_DEFINITION="$definition"
    export APOLLO_OAUTH_CLIENT_ID="$client_id"
    export APOLLO_OAUTH_CLIENT_SECRET="$client_secret"
    export APOLLO_OAUTH_RECORD_ID="$record_id"
    export APOLLO_OAUTH_BASE_DOMAIN="$base_domain"
    jq -nc '
      (env.APOLLO_OAUTH_DEFINITION | fromjson) as $definition |
      {key: $definition.key, value: {
        record_id: env.APOLLO_OAUTH_RECORD_ID,
        key: $definition.key,
        name: $definition.name,
        client_id: env.APOLLO_OAUTH_CLIENT_ID,
        client_secret: env.APOLLO_OAUTH_CLIENT_SECRET,
        is_public: ($definition.isPublic // false),
        grant_types: $definition.grantTypes,
        redirect_uris: ["https://app." + env.APOLLO_OAUTH_BASE_DOMAIN],
        post_logout_redirect_uris: ["https://app." + env.APOLLO_OAUTH_BASE_DOMAIN],
        scope: $definition.scope,
        skip_consent: ($definition.skipConsent // false)
      }}'
    unset APOLLO_OAUTH_DEFINITION APOLLO_OAUTH_CLIENT_ID APOLLO_OAUTH_CLIENT_SECRET
    unset APOLLO_OAUTH_RECORD_ID APOLLO_OAUTH_BASE_DOMAIN
  done
} | jq -sc 'from_entries')"

postgres_password="$(env_value "$secret_file" POSTGRES_PASSWORD)"
postgres_password_b64="$(printf '%s' "$postgres_password" | base64 | tr -d '\n')"
printf '%s' "$oauth_json" \
  | python3 "$renderer" \
  | DB_CONTAINER=apollo-platform-postgres \
    DB_USER=postgres \
    DB_NAME=apollo_deploy_platform \
    DB_PASS_B64="$postgres_password_b64" \
    bash "$psql_runner"
unset oauth_json postgres_password postgres_password_b64
info 'OAuth clients reconciled.'
