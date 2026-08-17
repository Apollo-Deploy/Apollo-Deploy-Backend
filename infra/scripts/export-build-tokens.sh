#!/usr/bin/env bash
# Export build secrets for Terraform / Docker (platform + signal dev images).
# Usage:  source infra/scripts/export-build-tokens.sh
#         eval "$(infra/scripts/export-build-tokens.sh --print)"

set -euo pipefail

npmrc="${NPMRC:-$HOME/.npmrc}"

if [[ ! -f "$npmrc" ]]; then
  echo "NPM_TOKEN missing: no $npmrc — run npm login or set NPM_TOKEN manually" >&2
  exit 1
fi

npm_token="$(grep -m1 '//registry.npmjs.org/:_authToken=' "$npmrc" | sed 's|.*:_authToken=||')"
if [[ -z "$npm_token" ]]; then
  echo "NPM_TOKEN missing: no //registry.npmjs.org/:_authToken in $npmrc" >&2
  exit 1
fi

if [[ "${1:-}" == "--print" ]]; then
  printf 'export NPM_TOKEN=%q\n' "$npm_token"
  exit 0
fi

export NPM_TOKEN="$npm_token"
echo "Exported NPM_TOKEN"
