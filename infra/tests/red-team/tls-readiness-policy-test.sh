#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
supervisor="$repo_root/infra/programs/nginx-supervisor.sh"
issuer="$repo_root/infra/programs/issue-certificates.sh"
deployer="$repo_root/infra/programs/deploy-remote.sh"

grep -q 'find -L /etc/letsencrypt/live' "$supervisor"
grep -q 'compose_run exec -T nginx nginx -t' "$issuer"
grep -q 'compose_run exec -T nginx nginx -s reload' "$issuer"
grep -q 'add_header X-Apollo-Service' "$issuer"
grep -q -- "--proto '=https' --tlsv1.2" "$deployer"
grep -q -- "--noproxy '\*'" "$deployer"
grep -q 'x-apollo-service:' "$deployer"
for expected in 'service == "iam"' 'service == "apollo-billing"'; do
  grep -q "$expected" "$deployer"
done
grep -q 'issue-certificates.sh' "$deployer"
grep -q 'exec 9>/opt/apollo/deploy.lock' "$deployer"
if grep -q 'deploy.lock' "$issuer"; then
  echo 'Certificate issuance must reuse the deployment transaction lock.' >&2
  exit 1
fi
echo 'TLS readiness-policy tests passed.'
