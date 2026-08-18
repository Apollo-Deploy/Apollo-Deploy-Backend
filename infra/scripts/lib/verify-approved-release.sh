#!/usr/bin/env bash

# Match one Terraform release_manifest value against the immutable release
# combinations reviewed and verified by CI. This deliberately performs no
# registry or Sigstore work on the deployment machine.
set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "Usage: $0 <approved-releases.json> < release-manifest.json" >&2
  exit 2
fi

approved_file="$1"
[ -f "$approved_file" ] && [ ! -L "$approved_file" ] \
  || {
    echo "ERROR: Approved release manifest is unavailable: $approved_file" >&2
    exit 1
  }

command -v jq >/dev/null 2>&1 \
  || {
    echo "ERROR: Required command is unavailable: jq" >&2
    exit 1
  }

release_file="$(mktemp /tmp/apollo-release.XXXXXX)"
cleanup() {
  rm -f -- "$release_file"
}
trap cleanup EXIT
cat >"$release_file"

if ! jq -e '
  def service($name; $repository):
    .[$name]
    | type == "object"
    and keys == ["image", "source_commit"]
    and (.image | test("^ghcr[.]io/apollo-deploy/" + $repository + "@sha256:[0-9a-f]{64}$"))
    and (.source_commit | test("^[0-9a-f]{40}$"));
  type == "object"
  and keys == ["billing", "platform", "signal"]
  and service("platform"; "apollo-platform-api")
  and service("signal"; "apollo-signal-api")
  and service("billing"; "apollo-billing-api")
' "$release_file" >/dev/null; then
  echo "ERROR: Terraform release_manifest does not have the immutable Apollo release shape." >&2
  exit 1
fi

if ! jq -e --slurpfile requested "$release_file" '
  def service($name; $repository):
    .[$name]
    | type == "object"
    and keys == ["image", "source_commit"]
    and (.image | test("^ghcr[.]io/apollo-deploy/" + $repository + "@sha256:[0-9a-f]{64}$"))
    and (.source_commit | test("^[0-9a-f]{40}$"));
  def release:
    type == "object"
    and keys == ["billing", "platform", "signal"]
    and service("platform"; "apollo-platform-api")
    and service("signal"; "apollo-signal-api")
    and service("billing"; "apollo-billing-api");
  .schema_version == 1
  and (keys == ["releases", "schema_version"])
  and (.releases | type == "array")
  and ([.releases[].id] | length == (unique | length))
  and all(.releases[];
    type == "object"
    and keys == ["approved_at", "id", "services"]
    and (.id | type == "string" and test("^[a-z0-9][a-z0-9._-]{0,63}$"))
    and (.approved_at | type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))
    and (.services | release)
  )
  and any(.releases[]; .services == $requested[0])
' "$approved_file" >/dev/null; then
  echo "ERROR: Release is absent from the CI-approved immutable manifest." >&2
  exit 1
fi

echo "==> Release exactly matches a CI-approved image/commit combination."
