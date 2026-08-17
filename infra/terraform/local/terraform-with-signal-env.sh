#!/usr/bin/env bash
set -euo pipefail
umask 077

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../../.." && pwd)"
signal_env="$repo_root/apollo-signal-api/.env"

if [[ ! -f "$signal_env" ]]; then
  echo "Missing Signal environment file: $signal_env" >&2
  exit 1
fi

set -a
# shellcheck disable=SC1090
source "$signal_env"
set +a

: "${APOLLO_SIGNAL_AWS_ACCESS_KEY_ID:?Missing APOLLO_SIGNAL_AWS_ACCESS_KEY_ID in $signal_env}"
: "${APOLLO_SIGNAL_AWS_SECRET_ACCESS_KEY:?Missing APOLLO_SIGNAL_AWS_SECRET_ACCESS_KEY in $signal_env}"
: "${APOLLO_SIGNAL_AWS_ACCOUNT_ID:?Missing APOLLO_SIGNAL_AWS_ACCOUNT_ID in $signal_env}"

export TF_VAR_aws_access_key_id="$APOLLO_SIGNAL_AWS_ACCESS_KEY_ID"
export TF_VAR_aws_secret_access_key="$APOLLO_SIGNAL_AWS_SECRET_ACCESS_KEY"
export TF_VAR_aws_account_id="$APOLLO_SIGNAL_AWS_ACCOUNT_ID"

exec terraform -chdir="$script_dir" "$@"
