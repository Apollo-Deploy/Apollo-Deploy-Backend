#!/usr/bin/env bash

# Exercise the exact Cosign image-attestation interface used by the publishers.
# The registry is loopback-only, the key is ephemeral, transparency upload is
# disabled, and --no-upload prevents any registry mutation.
set -euo pipefail

if [ "${APOLLO_CI_RELEASE_VERIFICATION:-false}" != true ]; then
  echo 'Cosign CLI smoke skipped outside release CI.'
  exit 0
fi

test_root="$(mktemp -d "${TMPDIR:-/tmp}/apollo-cosign-attest-smoke.XXXXXX")"
server_pid=''

cleanup() {
  if [ -n "$server_pid" ]; then
    kill "$server_pid" >/dev/null 2>&1 || true
    wait "$server_pid" >/dev/null 2>&1 || true
  fi
  rm -rf -- "$test_root"
}
trap cleanup EXIT

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

for command_name in python3 jq curl; do
  command -v "$command_name" >/dev/null 2>&1 \
    || fail "Required command is unavailable: $command_name"
done

if [ -n "${COSIGN_SMOKE_BIN:-}" ]; then
  [ -x "$COSIGN_SMOKE_BIN" ] || fail 'COSIGN_SMOKE_BIN is not executable.'
  cosign_command=("$COSIGN_SMOKE_BIN")
elif command -v cosign >/dev/null 2>&1; then
  cosign_command=("$(command -v cosign)")
else
  command -v go >/dev/null 2>&1 \
    || fail 'Cosign v3.0.6 or Go is required for the pinned CLI smoke test.'
  cosign_command=(go run github.com/sigstore/cosign/v3/cmd/cosign@v3.0.6)
fi

cosign_version="$("${cosign_command[@]}" version 2>/dev/null | awk '$1 == "GitVersion:" { print $2; exit }')"
[ "$cosign_version" = 'v3.0.6' ] \
  || fail "The CLI smoke test must run with pinned Cosign v3.0.6, not ${cosign_version:-unknown}."

manifest_file="$test_root/manifest.json"
printf '%s' '{"schemaVersion":2,"mediaType":"application/vnd.oci.image.manifest.v1+json","config":{"mediaType":"application/vnd.oci.image.config.v1+json","digest":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","size":2},"layers":[]}' > "$manifest_file"
manifest_digest="$(python3 - "$manifest_file" <<'PY'
import hashlib
import sys

with open(sys.argv[1], "rb") as source:
    print("sha256:" + hashlib.sha256(source.read()).hexdigest())
PY
)"

server_file="$test_root/registry.py"
port_file="$test_root/port"
cat > "$server_file" <<'PY'
from http.server import BaseHTTPRequestHandler, HTTPServer
import hashlib
import sys

manifest = open(sys.argv[1], "rb").read()
digest = "sha256:" + hashlib.sha256(manifest).hexdigest()
manifest_path = "/v2/apollo-smoke/manifests/" + digest

class RegistryHandler(BaseHTTPRequestHandler):
    def log_message(self, _format, *_args):
        return

    def send_manifest(self, include_body):
        self.send_response(200)
        self.send_header("Content-Type", "application/vnd.oci.image.manifest.v1+json")
        self.send_header("Content-Length", str(len(manifest)))
        self.send_header("Docker-Content-Digest", digest)
        self.end_headers()
        if include_body:
            self.wfile.write(manifest)

    def do_HEAD(self):
        if self.path == manifest_path:
            self.send_manifest(False)
        else:
            self.send_error(404)

    def do_GET(self):
        if self.path in ("/v2", "/v2/"):
            self.send_response(200)
            self.send_header("Docker-Distribution-API-Version", "registry/2.0")
            self.send_header("Content-Length", "0")
            self.end_headers()
        elif self.path == manifest_path:
            self.send_manifest(True)
        else:
            self.send_error(404)

server = HTTPServer(("127.0.0.1", 0), RegistryHandler)
with open(sys.argv[2], "w", encoding="utf-8") as port_output:
    port_output.write(str(server.server_port))
server.serve_forever()
PY

python3 "$server_file" "$manifest_file" "$port_file" &
server_pid="$!"
wait_count=0
while [ ! -s "$port_file" ]; do
  kill -0 "$server_pid" >/dev/null 2>&1 \
    || fail 'The loopback OCI registry exited before becoming ready.'
  wait_count=$((wait_count + 1))
  [ "$wait_count" -lt 400 ] || fail 'The loopback OCI registry did not become ready.'
  sleep 0.05
done
registry_port="$(cat "$port_file")"
curl --fail --silent --show-error "http://127.0.0.1:$registry_port/v2/" >/dev/null

key_prefix="$test_root/cosign-smoke"
COSIGN_PASSWORD='' "${cosign_command[@]}" generate-key-pair \
  --output-key-prefix "$key_prefix" >/dev/null

predicate_file="$test_root/predicate.json"
jq -n '{
  buildDefinition: {
    buildType: "https://actions.github.io/buildtypes/workflow/v1",
    externalParameters: {workflow: {
      repository: "https://github.com/Apollo-Deploy/Apollo-Platform-API",
      ref: "refs/heads/main",
      path: ".github/workflows/docker-publish.yml"
    }},
    internalParameters: {github: {eventName: "push"}},
    resolvedDependencies: [{
      uri: "git+https://github.com/Apollo-Deploy/Apollo-Platform-API@refs/heads/main",
      digest: {gitCommit: "1111111111111111111111111111111111111111"}
    }]
  },
  runDetails: {
    builder: {id: "https://github.com/Apollo-Deploy/Apollo-Platform-API/.github/workflows/docker-publish.yml@refs/heads/main"},
    metadata: {invocationId: "https://github.com/Apollo-Deploy/Apollo-Platform-API/actions/runs/123/attempts/1"}
  }
}' > "$predicate_file"

repository="127.0.0.1:$registry_port/apollo-smoke"
attestation_file="$test_root/attestation.json"
COSIGN_PASSWORD='' "${cosign_command[@]}" attest \
  --yes \
  --key "$key_prefix.key" \
  --tlog-upload=false \
  --use-signing-config=false \
  --no-upload \
  --allow-http-registry \
  --type slsaprovenance1 \
  --predicate "$predicate_file" \
  "$repository@$manifest_digest" > "$attestation_file"

jq -e \
  --arg repository "$repository" \
  --arg digest "${manifest_digest#sha256:}" '
    .payloadType == "application/vnd.in-toto+json" and
    (.payload | @base64d | fromjson |
      ._type == "https://in-toto.io/Statement/v0.1" and
      .subject == [{name: $repository, digest: {sha256: $digest}}] and
      .predicateType == "https://slsa.dev/provenance/v1" and
      .predicate.buildDefinition.buildType ==
        "https://actions.github.io/buildtypes/workflow/v1" and
      .predicate.buildDefinition.externalParameters.workflow == {
        repository: "https://github.com/Apollo-Deploy/Apollo-Platform-API",
        ref: "refs/heads/main",
        path: ".github/workflows/docker-publish.yml"
      } and
      .predicate.buildDefinition.internalParameters == {github: {eventName: "push"}} and
      .predicate.buildDefinition.resolvedDependencies == [{
        uri: "git+https://github.com/Apollo-Deploy/Apollo-Platform-API@refs/heads/main",
        digest: {gitCommit: "1111111111111111111111111111111111111111"}
      }] and
      .predicate.runDetails.builder == {
        id: "https://github.com/Apollo-Deploy/Apollo-Platform-API/.github/workflows/docker-publish.yml@refs/heads/main"
      } and
      .predicate.runDetails.metadata == {
        invocationId: "https://github.com/Apollo-Deploy/Apollo-Platform-API/actions/runs/123/attempts/1"
      })
  ' "$attestation_file" >/dev/null \
  || fail 'Cosign did not consume the SLSA v1 predicate and bind it to the exact image digest.'

echo 'Pinned Cosign image-attestation CLI smoke test passed.'
