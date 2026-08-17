#!/usr/bin/env bash

# CI-only registry verification for every committed production release.
# Credentials arrive as one protected JSON object on stdin; deployment hosts do
# not run this script and therefore do not require Cosign.
set -euo pipefail
umask 077

if [ "$#" -ne 1 ]; then
  echo "Usage: $0 <approved-releases.json> < ghcr-credentials.json" >&2
  exit 2
fi

approved_file="$1"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
provenance_verifier="$script_dir/verify-release-provenance.sh"
release_verifier="$script_dir/verify-approved-release.sh"
work_dir="$(mktemp -d /tmp/apollo-approved-releases.XXXXXX)"
credentials_file="$work_dir/credentials.json"

cleanup() {
  rm -rf -- "$work_dir"
}
trap cleanup EXIT
cat >"$credentials_file"
chmod 600 "$credentials_file"

jq -e '
  type == "object"
  and keys == ["token", "username"]
  and (.username | type == "string" and length > 0)
  and (.token | type == "string" and length > 0)
' "$credentials_file" >/dev/null \
  || { echo "ERROR: CI GHCR credentials are malformed." >&2; exit 1; }

jq -e '
  .schema_version == 1
  and (keys == ["releases", "schema_version"])
  and (.releases | type == "array")
  and ([.releases[].id] | length == (unique | length))
  and all(.releases[];
    type == "object"
    and keys == ["approved_at", "id", "services"]
    and (.id | type == "string" and test("^[a-z0-9][a-z0-9._-]{0,63}$"))
    and (.approved_at | type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))
  )
' "$approved_file" >/dev/null \
  || { echo "ERROR: Approved release catalog schema is invalid." >&2; exit 1; }

release_count="$(jq '.releases | length' "$approved_file")"
if [ "$release_count" -eq 0 ]; then
  echo "==> Approved release catalog is valid and currently empty."
  exit 0
fi

jq -c '.releases[].services' "$approved_file" |
  while IFS= read -r release_json; do
    printf '%s' "$release_json" |
      /bin/bash "$release_verifier" "$approved_file"
    jq -sc '{credentials: .[0], releases: .[1]}' \
      "$credentials_file" <(printf '%s' "$release_json") |
      /bin/bash "$provenance_verifier"
  done

echo "==> CI verified and approved $release_count immutable production release(s)."
