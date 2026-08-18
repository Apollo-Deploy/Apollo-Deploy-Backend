#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
file="$repo_root/infra/lib/vps.sh"
for option in '-F none' 'BatchMode=yes' 'IdentitiesOnly=yes' 'StrictHostKeyChecking=yes' 'ClearAllForwardings=yes' 'PermitLocalCommand=no' 'RequestTTY=no' 'UserKnownHostsFile='; do
  grep -q -- "$option" "$file" || {
    echo "FAIL: SSH policy omits $option" >&2
    exit 1
  }
done
grep -q '/etc/machine-id' "$file"
grep -Fq 'argument//' "$file"
grep -q "case \"\$phase\" in expand | contract | all" "$file"
# shellcheck source=../../lib/common.sh
source "$repo_root/infra/lib/common.sh"
# shellcheck source=../../lib/vps.sh
source "$file"
VPS_SSH=(bash -c "eval \"\$1\"" bash)
payload='safe; printf injected'
[[ "$(vps_ssh printf %s "$payload")" == "$payload" ]] || {
  echo 'FAIL: SSH argument quoting permitted remote shell injection.' >&2
  exit 1
}
echo 'SSH target-policy tests passed.'
