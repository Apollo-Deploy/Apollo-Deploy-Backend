#!/usr/bin/env bash
# Export build secrets for Terraform / Docker (platform + signal dev images).
# Usage:  source infra/scripts/export-build-tokens.sh
#         eval "$(infra/scripts/export-build-tokens.sh --print)"

set -euo pipefail

npmrc="${NPMRC:-$HOME/.npmrc}"
profile="${AWS_PROFILE:-apollo-codeartifact-publisher}"

if [[ ! -f "$npmrc" ]]; then
  echo "NPM_TOKEN missing: no $npmrc — run npm login or set NPM_TOKEN manually" >&2
  exit 1
fi

npm_token="$(grep -m1 '//registry.npmjs.org/:_authToken=' "$npmrc" | sed 's|.*:_authToken=||')"
if [[ -z "$npm_token" ]]; then
  echo "NPM_TOKEN missing: no //registry.npmjs.org/:_authToken in $npmrc" >&2
  exit 1
fi

if ! command -v aws &>/dev/null; then
  echo "aws CLI not found — install it to fetch CODEARTIFACT_AUTH_TOKEN" >&2
  exit 1
fi

codeartifact_token="$(AWS_PROFILE="$profile" aws codeartifact get-authorization-token \
  --domain apollo-deploy \
  --domain-owner 753668406194 \
  --region us-east-1 \
  --query authorizationToken \
  --output text)"

if [[ -z "$codeartifact_token" || "$codeartifact_token" == "None" ]]; then
  echo "CODEARTIFACT_AUTH_TOKEN missing: aws profile '$profile' could not fetch a token" >&2
  exit 1
fi

if [[ "${1:-}" == "--print" ]]; then
  printf 'export NPM_TOKEN=%q\n' "$npm_token"
  printf 'export CODEARTIFACT_AUTH_TOKEN=%q\n' "$codeartifact_token"
  exit 0
fi

export NPM_TOKEN="$npm_token"
export CODEARTIFACT_AUTH_TOKEN="$codeartifact_token"
echo "Exported NPM_TOKEN and CODEARTIFACT_AUTH_TOKEN (CodeArtifact profile: $profile)"
