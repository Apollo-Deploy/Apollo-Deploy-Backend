#!/usr/bin/env bash

CORS_POLICY_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/config/cors.env"

cors_origins_for() {
  local service="$1" base_domain="$2" policy_key policy_value label origins=''
  policy_key="${service}_CORS_ALLOWED_SUBDOMAINS"
  policy_value="$(env_value "$CORS_POLICY_FILE" "$policy_key")"
  [[ -n "$policy_value" && "$policy_value" != '*' ]] \
    || die "$policy_key must contain one or more exact subdomain labels."

  while IFS= read -r label; do
    [[ "$label" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] \
      || die "Invalid subdomain label in $policy_key: $label"
    [[ -z "$origins" ]] || origins+=','
    origins+="https://${label}.${base_domain}"
  done < <(printf '%s\n' "$policy_value" | tr ',' '\n')

  printf '%s' "$origins"
}

cors_testing_origins_for() {
  local service="$1" public_file="$2" policy_key policy_value origin port origins=''
  policy_key="${service}_CORS_TEST_ORIGINS"
  policy_value="$(env_value "$public_file" "$policy_key")"
  [[ -n "$policy_value" ]] || return 0

  while IFS= read -r origin; do
    [[ "$origin" =~ ^https?://localhost:([1-9][0-9]{0,4})$ ]] \
      || die "$policy_key may contain only exact localhost origins with explicit ports."
    port="${BASH_REMATCH[1]}"
    ((port <= 65535)) || die "Invalid localhost port in $policy_key: $port"
    [[ -z "$origins" ]] || origins+=','
    origins+="$origin"
  done < <(printf '%s\n' "$policy_value" | tr ',' '\n')

  printf '%s' "$origins"
}

ensure_local_config() {
  local public_file="$CONFIG_DIR/local.env"
  local secret_file="$CONFIG_DIR/local.secrets.env"
  if [[ ! -e "$public_file" && ! -L "$public_file" ]]; then
    write_protected_file "$public_file" <"$CONFIG_DIR/local.env.example"
  fi
  if [[ ! -e "$secret_file" && ! -L "$secret_file" ]]; then
    generate_secret_file | write_protected_file "$secret_file"
  fi
  validate_env_file "$public_file"
  require_protected_file "$public_file" 'Local configuration'
  validate_env_file "$secret_file"
  require_protected_file "$secret_file" 'Local secrets'
  validate_secret_contract "$secret_file" local
}

generate_secret_file() {
  local key
  for key in \
    POSTGRES_PASSWORD REDIS_PASSWORD PLATFORM_APP_DB_PASSWORD \
    PLATFORM_VERIFIER_DB_PASSWORD BILLING_APP_DB_PASSWORD \
    BILLING_SUPERUSER_DB_PASSWORD SIGNAL_APP_DB_PASSWORD \
    SIGNAL_SUPERUSER_DB_PASSWORD SESSION_SECRET AUTH_COOKIE_SECRET \
    INTERNAL_SERVICE_SECRET SIGNAL_EVENTS_SIGNING_SECRET; do
    printf '%s=%s\n' "$key" "$(random_secret)"
  done
  printf 'SIGNAL_WEBHOOK_SECRET_KEY=%s\n' "$(random_base64_key)"
  printf 'SIGNAL_IMPORT_CREDENTIALS_KEY=%s\n' "$(random_base64_key)"
  for key in PLATFORM SIGNAL BILLING; do
    printf '%s_OAUTH_CLIENT_ID=%s\n' "$key" "$(random_client_id)"
    printf '%s_OAUTH_CLIENT_SECRET=%s\n' "$key" "$(random_secret)"
    printf '%s_OAUTH_RECORD_ID=%s\n' "$key" "$(random_uuid)"
  done
  cat <<'EOF'
AWS_ACCESS_KEY_ID=
AWS_SECRET_ACCESS_KEY=
POLAR_API_KEY=
POLAR_WEBHOOK_SECRET=
KOOG_API_KEY=
GHCR_USERNAME=
GHCR_TOKEN=
R2_ACCOUNT_ID=
R2_ACCESS_KEY_ID=
R2_SECRET_ACCESS_KEY=
R2_BUCKET=
RESTIC_PASSWORD=
RESEND_API_KEY=
EOF
}

validate_secret_contract() {
  local secret_file="$1" target="${2:-vps}" key value decoded_length other_key other_value
  local required=(
    POSTGRES_PASSWORD REDIS_PASSWORD PLATFORM_APP_DB_PASSWORD
    PLATFORM_VERIFIER_DB_PASSWORD BILLING_APP_DB_PASSWORD
    BILLING_SUPERUSER_DB_PASSWORD SIGNAL_APP_DB_PASSWORD
    SIGNAL_SUPERUSER_DB_PASSWORD SESSION_SECRET AUTH_COOKIE_SECRET
    INTERNAL_SERVICE_SECRET
    PLATFORM_OAUTH_CLIENT_ID PLATFORM_OAUTH_CLIENT_SECRET PLATFORM_OAUTH_RECORD_ID
    SIGNAL_OAUTH_CLIENT_ID SIGNAL_OAUTH_CLIENT_SECRET SIGNAL_OAUTH_RECORD_ID
    BILLING_OAUTH_CLIENT_ID BILLING_OAUTH_CLIENT_SECRET BILLING_OAUTH_RECORD_ID
  )
  [[ "$target" != vps ]] || required+=(
    SIGNAL_EVENTS_SIGNING_SECRET SIGNAL_WEBHOOK_SECRET_KEY SIGNAL_IMPORT_CREDENTIALS_KEY
    RESEND_API_KEY
  )
  require_command openssl
  for key in "${required[@]}"; do
    value="$(env_value "$secret_file" "$key")"
    [[ ${#value} -ge 24 ]] || die "$key must contain at least 24 characters."
    [[ ! "$value" =~ ^(REPLACE_|CHANGE_ME|CHANGEME|PLACEHOLDER) ]] \
      || die "$key still contains a public placeholder value."
  done
  for key in PLATFORM SIGNAL BILLING; do
    value="$(env_value "$secret_file" "${key}_OAUTH_CLIENT_ID")"
    [[ "$value" =~ ^[A-Za-z]{32}$ ]] || die "${key}_OAUTH_CLIENT_ID must contain exactly 32 ASCII letters."
    value="$(env_value "$secret_file" "${key}_OAUTH_RECORD_ID")"
    [[ "$value" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] \
      || die "${key}_OAUTH_RECORD_ID must be a UUID."
  done
  for key in SIGNAL_WEBHOOK_SECRET_KEY SIGNAL_IMPORT_CREDENTIALS_KEY; do
    value="$(env_value "$secret_file" "$key")"
    [[ -n "$value" ]] || {
      [[ "$target" != vps ]] && continue
      die "$key is required in production."
    }
    decoded_length="$(printf '%s' "$value" | openssl base64 -d -A 2>/dev/null | wc -c | tr -d ' ')" \
      || die "$key must be valid standard Base64."
    [[ "$decoded_length" == 32 ]] || die "$key must encode exactly 32 bytes."
  done
  for key in "${required[@]}"; do
    [[ "$key" == *_OAUTH_CLIENT_ID || "$key" == *_OAUTH_RECORD_ID ]] && continue
    value="$(env_value "$secret_file" "$key")"
    for other_key in "${required[@]}"; do
      [[ "$other_key" == "$key" ]] && break
      [[ "$other_key" == *_OAUTH_CLIENT_ID || "$other_key" == *_OAUTH_RECORD_ID ]] && continue
      other_value="$(env_value "$secret_file" "$other_key")"
      [[ "$value" != "$other_value" ]] || die "$key must not reuse $other_key."
    done
  done
}

render_runtime() {
  local target="$1"
  local public_file="$2"
  local secret_file="$3"
  local aws_file="${4:-}"
  local runtime_dir="$5"
  local base_domain platform_host signal_host signal_tracking_cname_target billing_host platform_url
  local signal_email_received_meter_id
  local platform_cors_policy billing_cors_origins signal_cors_origins
  local platform_cors_testing_origins billing_cors_testing_origins signal_cors_testing_origins
  local session_secret events_secret webhook_secret import_key redis_password
  local primary_region regions_json trusted_clients service_clients
  local environment='production'
  local sources=("$secret_file" "$aws_file" "$public_file")

  [[ "$target" == local ]] && environment='development'
  validate_env_file "$public_file"
  validate_env_file "$secret_file"
  validate_env_file "$CORS_POLICY_FILE"
  validate_secret_contract "$secret_file" "$target"
  [[ -z "$aws_file" || ! -f "$aws_file" ]] || validate_env_file "$aws_file"
  mkdir -p "$runtime_dir/redis"
  chmod 700 "$runtime_dir" "$runtime_dir/redis"

  base_domain="$(env_value "$public_file" APOLLO_BASE_DOMAIN)"
  platform_host="$(env_value "$public_file" PLATFORM_HOST)"
  signal_host="$(env_value "$public_file" SIGNAL_HOST)"
  signal_tracking_cname_target="$(env_value "$public_file" SIGNAL_TRACKING_CNAME_TARGET)"
  billing_host="$(env_value "$public_file" BILLING_HOST)"
  signal_email_received_meter_id="$(env_value "$public_file" SIGNAL_EMAIL_RECEIVED_METER_ID '')"
  [[ "$base_domain" =~ ^[A-Za-z0-9.-]+$ ]] || die 'APOLLO_BASE_DOMAIN is invalid.'
  for host in "$platform_host" "$signal_host" "$billing_host"; do
    [[ "$host" =~ ^[A-Za-z0-9.-]+$ ]] || die "Invalid API hostname: $host"
  done
  [[ "$signal_tracking_cname_target" =~ ^[A-Za-z0-9.-]+$ ]] \
    || die 'SIGNAL_TRACKING_CNAME_TARGET is invalid.'
  if [[ "$target" == vps ]]; then
    [[ "$signal_email_received_meter_id" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] \
      || die 'SIGNAL_EMAIL_RECEIVED_METER_ID must be a UUID for VPS deployments.'
  fi
  platform_cors_policy="$(env_value "$CORS_POLICY_FILE" PLATFORM_CORS_ALLOWED_SUBDOMAINS)"
  [[ "$platform_cors_policy" == '*' ]] \
    || die 'PLATFORM_CORS_ALLOWED_SUBDOMAINS must be *.'
  billing_cors_origins="$(cors_origins_for BILLING "$base_domain")" || return 1
  signal_cors_origins="$(cors_origins_for SIGNAL "$base_domain")" || return 1
  platform_cors_testing_origins="$(cors_testing_origins_for PLATFORM "$public_file")" \
    || return 1
  billing_cors_testing_origins="$(cors_testing_origins_for BILLING "$public_file")" \
    || return 1
  signal_cors_testing_origins="$(cors_testing_origins_for SIGNAL "$public_file")" \
    || return 1
  [[ -z "$billing_cors_testing_origins" ]] \
    || billing_cors_origins+=",${billing_cors_testing_origins}"
  [[ -z "$signal_cors_testing_origins" ]] \
    || signal_cors_origins+=",${signal_cors_testing_origins}"
  platform_url="https://$platform_host"
  session_secret="$(env_value "$secret_file" SESSION_SECRET)"
  events_secret="$(env_value "$secret_file" SIGNAL_EVENTS_SIGNING_SECRET)"
  webhook_secret="$(env_value "$secret_file" SIGNAL_WEBHOOK_SECRET_KEY)"
  import_key="$(env_value "$secret_file" SIGNAL_IMPORT_CREDENTIALS_KEY)"
  redis_password="$(env_value "$secret_file" REDIS_PASSWORD)"
  primary_region="$(env_value "$public_file" AWS_REGION af-south-1)"
  regions_json="$(env_value "$public_file" AWS_REGIONS "$primary_region" | jq -Rc --arg primary "$primary_region" 'split(",") | map(select(length > 0 and . != $primary) | {region: .})')"
  trusted_clients="$(env_value "$secret_file" PLATFORM_OAUTH_CLIENT_ID),$(env_value "$secret_file" SIGNAL_OAUTH_CLIENT_ID),$(env_value "$secret_file" BILLING_OAUTH_CLIENT_ID)"
  service_clients="$trusted_clients"

  {
    printf 'POSTGRES_USER=postgres\nPOSTGRES_DB=apollo_deploy_platform\n'
    printf 'POSTGRES_PASSWORD=%s\n' "$(env_value "$secret_file" POSTGRES_PASSWORD)"
    printf 'POSTGRES_INITDB_ARGS=--auth-host=scram-sha-256\n'
  } | write_protected_file "$runtime_dir/data.env"

  {
    printf 'DB_HOST=apollo-platform-postgres\nDB_PORT=5432\nDB_USER=postgres\n'
    printf 'DB_PASSWORD=%s\nDB_NAME=apollo_deploy_platform\n' "$(env_value "$secret_file" POSTGRES_PASSWORD)"
    printf 'POOL_MODE=transaction\nMAX_CLIENT_CONN=200\nDEFAULT_POOL_SIZE=20\nRESERVE_POOL_SIZE=5\n'
    printf 'IGNORE_STARTUP_PARAMETERS=extra_float_digits,application_name,statement_timeout\n'
    printf 'AUTH_TYPE=scram-sha-256\nAUTH_USER=postgres\nAUTH_DBNAME=apollo_deploy_platform\nADMIN_USERS=postgres\n'
  } | write_protected_file "$runtime_dir/pgbouncer.env"

  printf 'REDIS_HEALTH_PASSWORD=%s\n' "$redis_password" | write_protected_file "$runtime_dir/redis.env"
  printf 'user default on #%s ~* &* +@all\n' "$(printf '%s' "$redis_password" | sha256_hex)" \
    | write_protected_file "$runtime_dir/redis/users.acl"

  {
    printf 'NODE_ENV=%s\nPORT=3000\nHOST=0.0.0.0\n' "$environment"
    printf 'PLATFORM_URL=%s\nPLATFORM_PUBLIC_URL=%s\nCORS_ALLOWED_DOMAIN=%s\n' "$platform_url" "$platform_url" "$base_domain"
    [[ -z "$platform_cors_testing_origins" ]] \
      || printf 'CORS_EXTRA_ORIGINS=%s\n' "$platform_cors_testing_origins"
    printf 'SESSION_SECRET=%s\nAUTH_COOKIE_SECRET=%s\n' "$session_secret" "$(env_value "$secret_file" AUTH_COOKIE_SECRET)"
    printf 'AUTH_SECURE_COOKIES=true\nAUTH_COOKIE_DOMAIN=.%s\nAUTH_COOKIE_SAMESITE=%s\n' \
      "$base_domain" "$([[ -n "$platform_cors_testing_origins" ]] && printf none || printf lax)"
    printf 'AUTH_LOGIN_URL=%s\nAUTH_CONSENT_URL=%s\n' "$(env_value "$public_file" AUTH_LOGIN_URL)" "$(env_value "$public_file" AUTH_CONSENT_URL)"
    printf 'AUTH_SECURITY_URL=%s\nAUTH_PASSKEYS_URL=%s\n' "$(env_value "$public_file" AUTH_SECURITY_URL)" "$(env_value "$public_file" AUTH_PASSKEYS_URL)"
    printf 'RESEND_API_KEY=%s\nRESEND_FROM_EMAIL=%s\n' "$(env_value "$secret_file" RESEND_API_KEY)" "$(env_value "$public_file" RESEND_FROM_EMAIL)"
    printf 'AUTH_DISABLE_ORIGIN_CHECK=false\nAUTH_DISABLE_CSRF_CHECK=false\n'
    printf 'PLATFORM_CLIENT_ID=%s\nPLATFORM_CLIENT_SECRET=%s\n' "$(env_value "$secret_file" PLATFORM_OAUTH_CLIENT_ID)" "$(env_value "$secret_file" PLATFORM_OAUTH_CLIENT_SECRET)"
    printf 'OAUTH_TRUSTED_CLIENT_IDS=%s\nOAUTH_SERVICE_CLIENT_IDS=%s\n' "$trusted_clients" "$service_clients"
    printf 'DB_HOST=apollo-platform-pgbouncer\nDB_PORT=5432\nDB_USER=platform_app\nDB_PASSWORD=%s\nDB_NAME=apollo_deploy_platform\nDB_POOL_MAX=10\n' "$(env_value "$secret_file" PLATFORM_APP_DB_PASSWORD)"
    printf 'DB_VERIFIER_ENABLED=true\nDB_VERIFIER_HOST=apollo-platform-postgres\nDB_VERIFIER_USER=platform_verifier\nDB_VERIFIER_PASSWORD=%s\n' "$(env_value "$secret_file" PLATFORM_VERIFIER_DB_PASSWORD)"
    printf 'SIGNAL_DB_NAME=apollo_deploy_signal\nREDIS_HOST=apollo-platform-redis\nREDIS_PORT=6379\nREDIS_PASSWORD=%s\nREDIS_TLS=false\n' "$redis_password"
    printf 'BILLING_BASE_URL=http://apollo-billing:3040\nSIGNAL_BASE_URL=http://apollo-signal:3030\nMETRICS_ENABLED=false\n'
  } | write_protected_file "$runtime_dir/platform.env"

  {
    printf 'APOLLO_SIGNAL_ENV=%s\nSIGNAL_PORT=3030\nSIGNAL_IMPORT_WORKERS_ENABLED=true\n' "$environment"
    printf 'SIGNAL_DB_HOST=apollo-platform-postgres\nSIGNAL_DB_PORT=5432\nSIGNAL_DB_NAME=apollo_deploy_signal\nSIGNAL_DB_USER=signal_app\nSIGNAL_DB_PASSWORD=%s\nSIGNAL_DB_SSLMODE=disable\n' "$(env_value "$secret_file" SIGNAL_APP_DB_PASSWORD)"
    printf 'REDIS_HOST=apollo-platform-redis\nREDIS_PORT=6379\nREDIS_PASSWORD=%s\n' "$redis_password"
    printf 'PLATFORM_URL=http://apollo-platform:3000\nPLATFORM_AUDIENCE_URL=%s\nPLATFORM_CLIENT_ID=%s\nPLATFORM_CLIENT_SECRET=%s\n' "$platform_url" "$(env_value "$secret_file" SIGNAL_OAUTH_CLIENT_ID)" "$(env_value "$secret_file" SIGNAL_OAUTH_CLIENT_SECRET)"
    printf 'AUTH_OAUTH_ISSUER_URL=%s\nAUTH_OAUTH_VALID_AUDIENCES=%s\nAUTH_JWKS_URL=http://apollo-platform:3000/auth/jwks\n' "$platform_url" "$platform_url"
    printf 'OAUTH_SERVICE_CLIENT_IDS=%s\nINTERNAL_SERVICE_SECRET=%s\nSESSION_SECRET=%s\nAUTH_SECURE_COOKIES=true\nCORS_ORIGINS=%s\n' "$service_clients" "$(env_value "$secret_file" INTERNAL_SERVICE_SECRET)" "$session_secret" "$signal_cors_origins"
    printf 'APOLLO_SIGNAL_AWS_REGION=%s\nAPOLLO_SIGNAL_AWS_REGIONS=%s\n' "$primary_region" "$regions_json"
    printf 'APOLLO_SIGNAL_AWS_ACCESS_KEY_ID=%s\nAPOLLO_SIGNAL_AWS_SECRET_ACCESS_KEY=%s\nAPOLLO_SIGNAL_AWS_ACCOUNT_ID=%s\n' "$(first_env_value AWS_ACCESS_KEY_ID '' "${sources[@]}")" "$(first_env_value AWS_SECRET_ACCESS_KEY '' "${sources[@]}")" "$(first_env_value AWS_ACCOUNT_ID '' "${sources[@]}")"
    printf 'APOLLO_SIGNAL_SES_CONFIGURATION_SET=%s\n' "$(first_env_value SIGNAL_SES_CONFIGURATION_SET apollo-signal "${sources[@]}")"
    printf 'APOLLO_SIGNAL_SQS_SCHEDULED_EMAIL_QUEUE_URL=%s\nAPOLLO_SIGNAL_DMARC_INBOUND_QUEUE_URL=%s\n' "$(first_env_value SIGNAL_SCHEDULED_EMAIL_QUEUE_URL '' "${sources[@]}")" "$(first_env_value SIGNAL_DMARC_INBOUND_QUEUE_URL '' "${sources[@]}")"
    printf 'APOLLO_SIGNAL_EVENTS_TOPIC_ARN=%s\nAPOLLO_SIGNAL_EVENTS_TOPIC_ARNS=%s\nAPOLLO_SIGNAL_DMARC_INBOUND_TOPIC_ARN=%s\n' "$(first_env_value SIGNAL_EVENTS_TOPIC_ARN '' "${sources[@]}")" "$(first_env_value SIGNAL_EVENTS_TOPIC_ARNS '' "${sources[@]}")" "$(first_env_value SIGNAL_DMARC_INBOUND_TOPIC_ARN '' "${sources[@]}")"
    printf 'APOLLO_SIGNAL_S3_CONTACT_IMAGES_BUCKET=%s\nAPOLLO_SIGNAL_DMARC_INBOUND_BUCKET=%s\n' "$(first_env_value SIGNAL_CONTACT_IMAGES_BUCKET '' "${sources[@]}")" "$(first_env_value SIGNAL_DMARC_INBOUND_BUCKET '' "${sources[@]}")"
    printf 'APOLLO_SIGNAL_S3_PROJECT_ARCHIVES_BUCKET=%s\nAPOLLO_SIGNAL_S3_PROJECT_ARCHIVES_KMS_KEY_ARN=%s\n' "$(first_env_value SIGNAL_PROJECT_ARCHIVES_BUCKET '' "${sources[@]}")" "$(first_env_value SIGNAL_PROJECT_ARCHIVES_KMS_KEY_ARN '' "${sources[@]}")"
    printf 'APOLLO_SIGNAL_TEMPLATE_MEDIA_PROVIDER=s3\nAPOLLO_SIGNAL_S3_TEMPLATE_MEDIA_BUCKET=%s\nAPOLLO_SIGNAL_TEMPLATE_MEDIA_PUBLIC_BASE_URL=%s\n' "$(first_env_value SIGNAL_TEMPLATE_MEDIA_BUCKET '' "${sources[@]}")" "$(first_env_value SIGNAL_TEMPLATE_MEDIA_PUBLIC_BASE_URL '' "${sources[@]}")"
    printf 'APOLLO_SIGNAL_EVENTS_SIGNING_SECRET=%s\nSIGNAL_WEBHOOK_SECRET_KEY=%s\nKMS_ROOT_KEY_B64=%s\n' "$events_secret" "$webhook_secret" "$import_key"
    printf 'SIGNAL_TRACKING_BASE_URL=https://%s\nSIGNAL_TRACKING_CNAME_TARGET=%s\n' \
      "$signal_host" "$signal_tracking_cname_target"
    printf 'APOLLO_SIGNAL_KOOG_API_KEY=%s\nAPOLLO_SIGNAL_KOOG_MODEL=deepseek-v4\n' \
      "$(env_value "$secret_file" KOOG_API_KEY)"
    printf 'SIGNAL_GEOIP_DB_PATH=/data/geoip/dbip-city-lite.mmdb\nBILLING_BASE_URL=http://apollo-billing:3040\n'
    printf 'NO_PROXY=localhost,127.0.0.1,apollo-billing,apollo-platform,apollo-platform-postgres,apollo-platform-redis,192.168.0.0/16,10.0.0.0/8\n'
    printf 'no_proxy=localhost,127.0.0.1,apollo-billing,apollo-platform,apollo-platform-postgres,apollo-platform-redis,192.168.0.0/16,10.0.0.0/8\n'
  } | write_protected_file "$runtime_dir/signal.env"

  {
    printf 'BILLING_PORT=3040\nAPOLLO_BILLING_ENV=%s\nCORS_ORIGINS=%s\n' "$environment" "$billing_cors_origins"
    printf 'PLATFORM_DB_HOST=apollo-platform-postgres\nPLATFORM_DB_PORT=5432\nPLATFORM_DB_NAME=apollo_deploy_platform\nPLATFORM_DB_USER=billing_app\nPLATFORM_DB_PASSWORD=%s\n' "$(env_value "$secret_file" BILLING_APP_DB_PASSWORD)"
    printf 'BILLING_SUPERUSER_PASSWORD=%s\nSIGNAL_DB_HOST=apollo-platform-postgres\nSIGNAL_DB_PORT=5432\nSIGNAL_DB_NAME=apollo_deploy_signal\n' "$(env_value "$secret_file" BILLING_SUPERUSER_DB_PASSWORD)"
    printf 'REDIS_HOST=apollo-platform-redis\nREDIS_PORT=6379\nREDIS_PASSWORD=%s\n' "$redis_password"
    printf 'PLATFORM_URL=http://apollo-platform:3000\nPLATFORM_AUDIENCE_URL=%s\nPLATFORM_CLIENT_ID=%s\nPLATFORM_CLIENT_SECRET=%s\n' "$platform_url" "$(env_value "$secret_file" BILLING_OAUTH_CLIENT_ID)" "$(env_value "$secret_file" BILLING_OAUTH_CLIENT_SECRET)"
    printf 'AUTH_JWKS_URL=http://apollo-platform:3000/auth/jwks\nAUTH_OAUTH_ISSUER_URL=%s\nAUTH_OAUTH_VALID_AUDIENCES=%s\nOAUTH_SERVICE_CLIENT_IDS=%s\n' "$platform_url" "$platform_url" "$service_clients"
    printf 'POLAR_API_KEY=%s\nPOLAR_WEBHOOK_SECRET=%s\nPOLAR_API_BASE_URL=%s\n' "$(env_value "$secret_file" POLAR_API_KEY)" "$(env_value "$secret_file" POLAR_WEBHOOK_SECRET)" "$(env_value "$public_file" POLAR_API_BASE_URL https://api.polar.sh)"
    [[ -z "$signal_email_received_meter_id" ]] \
      || printf 'SIGNAL_EMAIL_RECEIVED_METER_ID=%s\n' "$signal_email_received_meter_id"
  } | write_protected_file "$runtime_dir/billing.env"

  {
    printf 'PGHOST=apollo-platform-postgres\nPGPORT=5432\nPGUSER=postgres\nPGPASSWORD=%s\nPGDATABASE=postgres\nPGSSLMODE=disable\n' "$(env_value "$secret_file" POSTGRES_PASSWORD)"
    printf 'BACKUP_INTERVAL_SECONDS=86400\nBACKUP_RETRY_INTERVAL_SECONDS=300\nBACKUP_RETENTION_COUNT=7\nBACKUP_MAX_AGE_SECONDS=93600\n'
  } | write_protected_file "$runtime_dir/backup.env"

  {
    printf 'RESTIC_REPOSITORY=s3:https://%s.r2.cloudflarestorage.com/%s\n' "$(env_value "$secret_file" R2_ACCOUNT_ID)" "$(env_value "$secret_file" R2_BUCKET)"
    printf 'RESTIC_PASSWORD=%s\nAWS_ACCESS_KEY_ID=%s\nAWS_SECRET_ACCESS_KEY=%s\n' "$(env_value "$secret_file" RESTIC_PASSWORD)" "$(env_value "$secret_file" R2_ACCESS_KEY_ID)" "$(env_value "$secret_file" R2_SECRET_ACCESS_KEY)"
    printf 'BACKUP_RETENTION_COUNT=7\nOFFSITE_INTERVAL_SECONDS=86400\nOFFSITE_MAX_AGE_SECONDS=87300\n'
  } | write_protected_file "$runtime_dir/offsite.env"
}
