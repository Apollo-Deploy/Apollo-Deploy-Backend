#!/usr/bin/env bash

ensure_vps_public_config() {
  VPS_PUBLIC_FILE="$CONFIG_DIR/vps.env"
  VPS_SECRET_FILE="$CONFIG_DIR/vps.secrets.env"
  VPS_AWS_FILE="$CONFIG_DIR/vps.aws.env"
  export VPS_AWS_FILE
  [[ -f "$VPS_PUBLIC_FILE" ]] \
    || die "VPS config is missing. Copy $CONFIG_DIR/vps.env.example to $VPS_PUBLIC_FILE and review every target value."
  require_protected_file "$VPS_PUBLIC_FILE" 'VPS configuration'
  validate_env_file "$VPS_PUBLIC_FILE"
}

ensure_vps_config() {
  local allow_generate="${1:-false}"
  ensure_vps_public_config
  if [[ ! -f "$VPS_SECRET_FILE" ]]; then
    [[ "$allow_generate" == true ]] \
      || die "VPS secrets are missing: $VPS_SECRET_FILE"
    generate_secret_file | write_protected_file "$VPS_SECRET_FILE"
  fi
  require_protected_file "$VPS_SECRET_FILE" 'VPS secrets'
  validate_env_file "$VPS_SECRET_FILE"
  validate_secret_contract "$VPS_SECRET_FILE" vps
}

terraform_context() {
  ensure_vps_public_config
  require_command terraform
  require_command jq
  require_command aws
  local account region actual_account
  account="$(env_value "$VPS_PUBLIC_FILE" AWS_ACCOUNT_ID)"
  region="$(env_value "$VPS_PUBLIC_FILE" AWS_REGION)"
  [[ "$account" =~ ^[0-9]{12}$ ]] || die 'AWS_ACCOUNT_ID is invalid.'
  actual_account="$(aws sts get-caller-identity --query Account --output text)" \
    || die 'Could not verify the active AWS account.'
  [[ "$actual_account" == "$account" ]] \
    || die "Wrong AWS account: expected $account, authenticated as $actual_account"

  TF_WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/apollo-terraform.XXXXXX")"
  TF_VARS_FILE="$TF_WORK_DIR/vps.auto.tfvars.json"
  TF_BACKEND_FILE="$TF_WORK_DIR/backend.hcl"
  chmod 700 "$TF_WORK_DIR"

  local regions proxied bucket_overrides restore_principals
  regions="$(env_value "$VPS_PUBLIC_FILE" AWS_REGIONS "$region")"
  proxied="$(env_value "$VPS_PUBLIC_FILE" CLOUDFLARE_PROXIED false)"
  bucket_overrides="$(env_value "$VPS_PUBLIC_FILE" AWS_BUCKET_NAME_OVERRIDES_JSON '{}')"
  restore_principals="$(env_value "$VPS_PUBLIC_FILE" AWS_SUPPORT_RESTORE_TRUSTED_PRINCIPAL_ARNS '')"
  [[ "$proxied" == true || "$proxied" == false ]] || die 'CLOUDFLARE_PROXIED must be true or false.'
  jq -e 'type == "object" and all(keys[]; test("^[a-z0-9-]+$")) and all(.[]; type == "string")' \
    <<<"$bucket_overrides" >/dev/null || die 'AWS_BUCKET_NAME_OVERRIDES_JSON must be a string-to-string JSON object.'
  local active_dmarc_rule_set expected_dmarc_rule_set
  expected_dmarc_rule_set="apollo-production-signal-dmarc-inbound"
  active_dmarc_rule_set="$(
    aws ses describe-active-receipt-rule-set \
      --region "$region" \
      --query 'Metadata.Name' \
      --output text
  )" || die 'Could not inspect the active SES receipt rule set.'
  [[ -z "$active_dmarc_rule_set" || "$active_dmarc_rule_set" == None || "$active_dmarc_rule_set" == "$expected_dmarc_rule_set" ]] \
    || die "Refusing to replace active SES receipt rule set: $active_dmarc_rule_set"

  local APOLLO_TF_BASE_DOMAIN APOLLO_TF_PLATFORM_HOST APOLLO_TF_SIGNAL_HOST
  local APOLLO_TF_BILLING_HOST APOLLO_TF_CF_ZONE APOLLO_TF_CF_ORIGIN
  local APOLLO_TF_CF_PROXIED APOLLO_TF_AWS_ACCOUNT APOLLO_TF_AWS_REGION
  local APOLLO_TF_AWS_REGIONS APOLLO_TF_ALERT_TOPIC APOLLO_TF_ARCHIVE_DAYS
  local APOLLO_TF_BUCKET_OVERRIDES APOLLO_TF_RESTORE_PRINCIPALS
  APOLLO_TF_BASE_DOMAIN="$(env_value "$VPS_PUBLIC_FILE" APOLLO_BASE_DOMAIN)"
  APOLLO_TF_PLATFORM_HOST="$(env_value "$VPS_PUBLIC_FILE" PLATFORM_HOST)"
  APOLLO_TF_SIGNAL_HOST="$(env_value "$VPS_PUBLIC_FILE" SIGNAL_HOST)"
  APOLLO_TF_BILLING_HOST="$(env_value "$VPS_PUBLIC_FILE" BILLING_HOST)"
  APOLLO_TF_CF_ZONE="$(env_value "$VPS_PUBLIC_FILE" CLOUDFLARE_ZONE_ID)"
  APOLLO_TF_CF_ORIGIN="$(env_value "$VPS_PUBLIC_FILE" CLOUDFLARE_ORIGIN_IPV4)"
  APOLLO_TF_CF_PROXIED="$proxied"
  APOLLO_TF_AWS_ACCOUNT="$account"
  APOLLO_TF_AWS_REGION="$region"
  APOLLO_TF_AWS_REGIONS="$regions"
  APOLLO_TF_ALERT_TOPIC="$(env_value "$VPS_PUBLIC_FILE" AWS_OPERATOR_ALERT_TOPIC_ARN)"
  APOLLO_TF_ARCHIVE_DAYS="$(env_value "$VPS_PUBLIC_FILE" SIGNAL_ARCHIVE_RETENTION_DAYS 2555)"
  APOLLO_TF_BUCKET_OVERRIDES="$bucket_overrides"
  APOLLO_TF_RESTORE_PRINCIPALS="$restore_principals"
  export APOLLO_TF_BASE_DOMAIN APOLLO_TF_PLATFORM_HOST APOLLO_TF_SIGNAL_HOST
  export APOLLO_TF_BILLING_HOST APOLLO_TF_CF_ZONE APOLLO_TF_CF_ORIGIN
  export APOLLO_TF_CF_PROXIED APOLLO_TF_AWS_ACCOUNT APOLLO_TF_AWS_REGION
  export APOLLO_TF_AWS_REGIONS APOLLO_TF_ALERT_TOPIC APOLLO_TF_ARCHIVE_DAYS
  export APOLLO_TF_BUCKET_OVERRIDES APOLLO_TF_RESTORE_PRINCIPALS
  jq -n '
    {
      environment: "production",
      base_domain: env.APOLLO_TF_BASE_DOMAIN,
      api_hosts: {
        platform: env.APOLLO_TF_PLATFORM_HOST,
        signal: env.APOLLO_TF_SIGNAL_HOST,
        billing: env.APOLLO_TF_BILLING_HOST
      },
      cloudflare: {
        zone_id: env.APOLLO_TF_CF_ZONE,
        origin_ipv4: env.APOLLO_TF_CF_ORIGIN,
        proxied: (env.APOLLO_TF_CF_PROXIED == "true")
      },
      aws: {
        account_id: env.APOLLO_TF_AWS_ACCOUNT,
        region: env.APOLLO_TF_AWS_REGION,
        operator_alert_topic_arn: env.APOLLO_TF_ALERT_TOPIC,
        archive_retention_days: (env.APOLLO_TF_ARCHIVE_DAYS | tonumber),
        bucket_name_overrides: (env.APOLLO_TF_BUCKET_OVERRIDES | fromjson),
        support_restore_trusted_principal_arns: (env.APOLLO_TF_RESTORE_PRINCIPALS | split(",") | map(select(length > 0)))
      },
      signal: {
        supported_regions: (env.APOLLO_TF_AWS_REGIONS | split(",") | map(select(length > 0)))
      }
    }' >"$TF_VARS_FILE"
  unset APOLLO_TF_BASE_DOMAIN APOLLO_TF_PLATFORM_HOST APOLLO_TF_SIGNAL_HOST
  unset APOLLO_TF_BILLING_HOST APOLLO_TF_CF_ZONE APOLLO_TF_CF_ORIGIN
  unset APOLLO_TF_CF_PROXIED APOLLO_TF_AWS_ACCOUNT APOLLO_TF_AWS_REGION
  unset APOLLO_TF_AWS_REGIONS APOLLO_TF_ALERT_TOPIC APOLLO_TF_ARCHIVE_DAYS
  unset APOLLO_TF_BUCKET_OVERRIDES APOLLO_TF_RESTORE_PRINCIPALS

  local bucket key backend_region kms_key
  bucket="$(env_value "$VPS_PUBLIC_FILE" AWS_STATE_BUCKET)"
  key="$(env_value "$VPS_PUBLIC_FILE" AWS_STATE_KEY production/terraform.tfstate)"
  backend_region="$(env_value "$VPS_PUBLIC_FILE" AWS_STATE_REGION "$region")"
  kms_key="$(env_value "$VPS_PUBLIC_FILE" AWS_STATE_KMS_KEY_ID)"
  [[ "$bucket" =~ ^[a-z0-9.-]+$ && "$key" =~ ^[A-Za-z0-9._/-]+$ && "$backend_region" =~ ^[a-z0-9-]+$ ]] \
    || die 'Invalid Terraform backend coordinates.'
  {
    printf 'bucket = "%s"\nkey = "%s"\nregion = "%s"\n' "$bucket" "$key" "$backend_region"
    printf 'encrypt = true\nuse_lockfile = true\nallowed_account_ids = ["%s"]\n' "$account"
    [[ -z "$kms_key" ]] || printf 'kms_key_id = "%s"\n' "$kms_key"
  } >"$TF_BACKEND_FILE"
  chmod 600 "$TF_VARS_FILE" "$TF_BACKEND_FILE"

  terraform -chdir="$SCRIPT_DIR/terraform/vps" init -reconfigure -input=false \
    -backend-config="$TF_BACKEND_FILE" -lockfile=readonly -no-color
}

cleanup_terraform_context() {
  [[ -z "${TF_WORK_DIR:-}" ]] || rm -rf -- "$TF_WORK_DIR"
  unset TF_WORK_DIR TF_VARS_FILE TF_BACKEND_FILE
}

terraform_saved_plan() {
  local subscription_enabled="${1:-true}"
  terraform_context
  TF_PLAN_FILE="$TF_WORK_DIR/vps.tfplan"
  terraform -chdir="$SCRIPT_DIR/terraform/vps" plan \
    -var-file="$TF_VARS_FILE" \
    -var="enable_ses_feedback_subscription=$subscription_enabled" \
    -lock-timeout=5m -input=false -out="$TF_PLAN_FILE" -no-color
  terraform -chdir="$SCRIPT_DIR/terraform/vps" show -no-color "$TF_PLAN_FILE"
}

terraform_plan_external() {
  trap cleanup_terraform_context EXIT
  terraform_saved_plan true
  info 'Plan created and displayed; no infrastructure was changed.'
}

terraform_apply_external() {
  local subscription_enabled="${1:-true}"
  trap cleanup_terraform_context EXIT
  terraform_saved_plan "$subscription_enabled"
  confirm_target 'Apply this exact reviewed external-infrastructure plan?'
  terraform -chdir="$SCRIPT_DIR/terraform/vps" apply \
    -lock-timeout=5m -input=false -no-color "$TF_PLAN_FILE"
  cleanup_terraform_context
  trap - EXIT
}

write_signal_aws_runtime() {
  local target="$1"
  trap cleanup_terraform_context EXIT
  terraform_context
  local public_json credential_json
  public_json="$(terraform -chdir="$SCRIPT_DIR/terraform/vps" output -json signal_aws)"
  credential_json="$(terraform -chdir="$SCRIPT_DIR/terraform/vps" output -json signal_runtime_credentials)"
  {
    printf 'AWS_ACCOUNT_ID=%s\n' "$(jq -r '.account_id' <<<"$public_json")"
    printf 'AWS_ACCESS_KEY_ID=%s\nAWS_SECRET_ACCESS_KEY=%s\n' \
      "$(jq -r '.access_key_id' <<<"$credential_json")" \
      "$(jq -r '.secret_access_key' <<<"$credential_json")"
    printf 'SIGNAL_SES_CONFIGURATION_SET=%s\n' "$(jq -r '.configuration_set' <<<"$public_json")"
    printf 'SIGNAL_SCHEDULED_EMAIL_QUEUE_URL=%s\nSIGNAL_DMARC_INBOUND_QUEUE_URL=%s\n' \
      "$(jq -r '.queue_urls.scheduled_email' <<<"$public_json")" \
      "$(jq -r '.queue_urls.dmarc_inbound' <<<"$public_json")"
    printf 'SIGNAL_EVENTS_TOPIC_ARN=%s\nSIGNAL_EVENTS_TOPIC_ARNS=%s\n' \
      "$(jq -r '.event_topic_arn' <<<"$public_json")" \
      "$(jq -r '[.event_topic_arns[]] | join(",")' <<<"$public_json")"
    printf 'SIGNAL_DMARC_INBOUND_TOPIC_ARN=%s\n' "$(jq -r '.dmarc_inbound_topic_arn' <<<"$public_json")"
    printf 'SIGNAL_CONTACT_IMAGES_BUCKET=%s\nSIGNAL_TEMPLATE_MEDIA_BUCKET=%s\nSIGNAL_DMARC_INBOUND_BUCKET=%s\nSIGNAL_PROJECT_ARCHIVES_BUCKET=%s\n' \
      "$(jq -r '.buckets.contact_images' <<<"$public_json")" \
      "$(jq -r '.buckets.template_media' <<<"$public_json")" \
      "$(jq -r '.buckets.dmarc_inbound' <<<"$public_json")" \
      "$(jq -r '.buckets.project_archives' <<<"$public_json")"
    printf 'SIGNAL_PROJECT_ARCHIVES_KMS_KEY_ARN=%s\n' "$(jq -r '.project_archives_kms_key_arn' <<<"$public_json")"
  } | write_protected_file "$target"
  unset public_json credential_json
  cleanup_terraform_context
  trap - EXIT
}
