#!/usr/bin/env bash

set -euo pipefail

test_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$test_dir/../../.." && pwd)"
verifier="$repo_root/infra/scripts/lib/verify-release-provenance.sh"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/apollo-release-provenance-tests.XXXXXX")"

cleanup() {
  rm -rf -- "$test_root"
}
trap cleanup EXIT

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

mkdir -p "$test_root/bin" "$test_root/objects"

cat > "$test_root/bin/curl" <<'CURL'
#!/usr/bin/env bash
set -euo pipefail

while IFS= read -r environment_entry; do
  case "$environment_entry" in
    *registry-test-token*|*fixture-registry-token*|*YXBvbGxvLXRlc3Q6cmVnaXN0cnktdGVzdC10b2tlbg==*)
      echo 'registry credential leaked into curl environment' >&2
      exit 1
      ;;
  esac
done < <(env)

headers="$(cat)"
output_file=""
url=""
previous=""
saw_location=false
saw_https_redirect=false
saw_bounded_redirects=false
for argument in "$@"; do
  case "$previous" in
    output) output_file="$argument"; previous=""; continue ;;
    proto_redir)
      [ "$argument" = '=https' ] && saw_https_redirect=true
      previous=""
      continue
      ;;
    max_redirs)
      [ "$argument" = 3 ] && saw_bounded_redirects=true
      previous=""
      continue
      ;;
  esac
  case "$argument" in
    --output) previous=output ;;
    --location) saw_location=true ;;
    --proto-redir) previous=proto_redir ;;
    --max-redirs) previous=max_redirs ;;
    https://*) url="$argument" ;;
    *registry-test-token*|*fixture-registry-token*|*YXBvbGxvLXRlc3Q6cmVnaXN0cnktdGVzdC10b2tlbg==*)
      echo 'registry credential leaked into curl arguments' >&2
      exit 1
      ;;
  esac
done
[ -n "$output_file" ] && [ -n "$url" ]

case "$url" in
  https://ghcr.io/token)
    case "$headers" in
      'Authorization: Basic '*$'\n''Accept: application/json') ;;
      *) echo 'missing protected basic authorization header' >&2; exit 1 ;;
    esac
    printf '%s' '{"token":"fixture-registry-token"}' > "$output_file"
    ;;
  https://ghcr.io/v2/*/manifests/sha256:*|https://ghcr.io/v2/*/blobs/sha256:*)
    [ "$saw_location" = true ] \
      && [ "$saw_https_redirect" = true ] \
      && [ "$saw_bounded_redirects" = true ] \
      || { echo 'registry object fetch does not enforce bounded HTTPS redirects' >&2; exit 1; }
    case "$headers" in
      'Authorization: Bearer fixture-registry-token'$'\n''Accept: '*) ;;
      *) echo 'missing protected registry bearer header' >&2; exit 1 ;;
    esac
    digest="${url##*/}"
    [ -f "$APOLLO_PROVENANCE_OBJECTS/$digest" ] \
      || { echo "fixture object is missing: $digest" >&2; exit 22; }
    cp "$APOLLO_PROVENANCE_OBJECTS/$digest" "$output_file"
    ;;
  *)
    echo "unexpected registry URL: $url" >&2
    exit 1
    ;;
esac
CURL

cat > "$test_root/bin/cosign" <<'COSIGN'
#!/usr/bin/env bash
set -euo pipefail

fixture_root="$(cd "$(dirname "$0")/.." && pwd)"

if [ "${1:-}" = version ]; then
  printf '%s\n' 'GitVersion:    v3.0.6'
  exit 0
fi

for argument in "$@"; do
  case "$argument" in
    *registry-test-token*|*fixture-registry-token*|*YXBvbGxvLXRlc3Q6cmVnaXN0cnktdGVzdC10b2tlbg==*)
      echo 'registry credential leaked into cosign arguments' >&2
      exit 1
      ;;
  esac
done
while IFS= read -r environment_entry; do
  case "$environment_entry" in
    *registry-test-token*|*fixture-registry-token*|*YXBvbGxvLXRlc3Q6cmVnaXN0cnktdGVzdC10b2tlbg==*)
      echo 'registry credential leaked into cosign environment' >&2
      exit 1
      ;;
  esac
done < <(env)

[ -n "${DOCKER_CONFIG:-}" ] || { echo 'missing protected Docker config path' >&2; exit 1; }
[ -f "$DOCKER_CONFIG/config.json" ] || { echo 'missing protected Docker config' >&2; exit 1; }
actual_auth="$(jq -er '.auths["ghcr.io"].auth' "$DOCKER_CONFIG/config.json")"
expected_auth="$(printf '%s' 'apollo-test:registry-test-token' | base64 | tr -d '\r\n')"
[ "$actual_auth" = "$expected_auth" ] || { echo 'incorrect Docker credential binding' >&2; exit 1; }
config_mode="$(stat -f '%Lp' "$DOCKER_CONFIG/config.json" 2>/dev/null || stat -c '%a' "$DOCKER_CONFIG/config.json")"
[ "$config_mode" = 600 ] || { echo "unsafe Docker config mode: $config_mode" >&2; exit 1; }
unset actual_auth expected_auth

subcommand="$1"
shift
case "$subcommand" in
  verify|verify-attestation) ;;
  *) echo "unexpected cosign subcommand: $subcommand" >&2; exit 1 ;;
esac

requested_issuer=""
requested_identity=""
requested_repository=""
requested_ref=""
requested_sha=""
requested_trigger=""
requested_type=""
image=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --certificate-oidc-issuer)
      requested_issuer="$2"
      shift 2
      ;;
    --certificate-identity)
      requested_identity="$2"
      shift 2
      ;;
    --certificate-github-workflow-repository)
      requested_repository="$2"
      shift 2
      ;;
    --certificate-github-workflow-ref)
      requested_ref="$2"
      shift 2
      ;;
    --certificate-github-workflow-sha)
      requested_sha="$2"
      shift 2
      ;;
    --certificate-github-workflow-trigger)
      requested_trigger="$2"
      shift 2
      ;;
    --type)
      requested_type="$2"
      shift 2
      ;;
    --timeout|--output)
      shift 2
      ;;
    ghcr.io/*@sha256:*)
      image="$1"
      shift
      ;;
    *)
      echo "unexpected cosign option: $1" >&2
      exit 1
      ;;
  esac
done

case "$image" in
  ghcr.io/apollo-deploy/apollo-platform-api@sha256:*)
    source_repository='Apollo-Deploy/Apollo-Platform-API'
    source_ref='refs/heads/main'
    ;;
  ghcr.io/apollo-deploy/apollo-signal-api@sha256:*)
    source_repository='Apollo-Deploy/Apollo-Signal-API'
    source_ref='refs/heads/development'
    ;;
  ghcr.io/apollo-deploy/apollo-billing-api@sha256:*)
    source_repository='Apollo-Deploy/Apollo-Billing-API'
    source_ref='refs/heads/main'
    ;;
  *)
    echo "unexpected signed subject: $image" >&2
    exit 1
    ;;
esac

mode="$(cat "$fixture_root/cosign-mode")"
actual_issuer='https://token.actions.githubusercontent.com'
actual_repository="$source_repository"
actual_ref="$source_ref"
actual_sha='1111111111111111111111111111111111111111'
actual_identity="https://github.com/$source_repository/.github/workflows/docker-publish.yml@$actual_ref"
actual_trigger='push'

case "$mode" in
  valid|forged-provenance) ;;
  unsigned|forged-label)
    [ "$subcommand" != verify ] || exit 1
    ;;
  missing-attestation)
    [ "$subcommand" != verify-attestation ] || exit 1
    ;;
  wrong-issuer)
    actual_issuer='https://issuer.example.invalid'
    ;;
  wrong-repository)
    actual_repository='Attacker/Apollo-Service-API'
    ;;
  wrong-workflow)
    actual_identity="https://github.com/$source_repository/.github/workflows/untrusted.yml@$actual_ref"
    ;;
  wrong-ref)
    actual_ref='refs/heads/untrusted'
    actual_identity="https://github.com/$source_repository/.github/workflows/docker-publish.yml@$actual_ref"
    ;;
  wrong-commit)
    actual_sha='2222222222222222222222222222222222222222'
    ;;
  *)
    echo "unknown cosign fixture mode: $mode" >&2
    exit 1
    ;;
esac

provenance_sha="$actual_sha"
if [ "$mode" = forged-provenance ]; then
  provenance_sha='2222222222222222222222222222222222222222'
fi

[ "$requested_issuer" = "$actual_issuer" ] || exit 1
[ "$requested_identity" = "$actual_identity" ] || exit 1
[ "$requested_repository" = "$actual_repository" ] || exit 1
[ "$requested_ref" = "$actual_ref" ] || exit 1
[ "$requested_sha" = "$actual_sha" ] || exit 1
[ "$requested_trigger" = "$actual_trigger" ] || exit 1
if [ "$subcommand" = verify-attestation ]; then
  [ "$requested_type" = slsaprovenance1 ] || exit 1
else
  [ -z "$requested_type" ] || exit 1
fi

printf '%s %s\n' "$subcommand" "$image" >> "$fixture_root/cosign-invocations"
if [ "$subcommand" = verify ]; then
  printf '%s\n' '{"verified":true}'
else
  subject_repository="${image%@sha256:*}"
  subject_digest="${image##*@sha256:}"
  statement="$(jq -cn \
    --arg subject_repository "$subject_repository" \
    --arg subject_digest "$subject_digest" \
    --arg source_repository "$source_repository" \
    --arg source_ref "$actual_ref" \
    --arg source_commit "$provenance_sha" \
    --arg builder_id "$actual_identity" '
      {
        _type: "https://in-toto.io/Statement/v0.1",
        subject: [{name: $subject_repository, digest: {sha256: $subject_digest}}],
        predicateType: "https://slsa.dev/provenance/v1",
        predicate: {
          buildDefinition: {
            buildType: "https://actions.github.io/buildtypes/workflow/v1",
            externalParameters: {workflow: {
              repository: ("https://github.com/" + $source_repository),
              ref: $source_ref,
              path: ".github/workflows/docker-publish.yml"
            }},
            internalParameters: {github: {eventName: "push"}},
            resolvedDependencies: [{
              uri: ("git+https://github.com/" + $source_repository + "@" + $source_ref),
              digest: {gitCommit: $source_commit}
            }]
          },
          runDetails: {
            builder: {id: $builder_id},
            metadata: {
              invocationId: ("https://github.com/" + $source_repository + "/actions/runs/123/attempts/1")
            }
          }
        }
      }
    ')"
  payload="$(printf '%s' "$statement" | base64 | tr -d '\r\n')"
  printf '{"payload":"%s"}\n' "$payload"
fi
COSIGN

chmod 700 "$test_root/bin/curl" "$test_root/bin/cosign"

object_counter=0
REGISTERED_DIGEST=''
REGISTERED_SIZE=''
register_object() {
  local content="$1"
  local source_file

  object_counter=$((object_counter + 1))
  source_file="$test_root/object-$object_counter.json"
  printf '%s' "$content" > "$source_file"
  REGISTERED_DIGEST="$(python3 - "$source_file" <<'PY'
import hashlib
import sys

with open(sys.argv[1], "rb") as source:
    print("sha256:" + hashlib.sha256(source.read()).hexdigest())
PY
)"
  REGISTERED_SIZE="$(wc -c < "$source_file" | tr -d ' ')"
  cp "$source_file" "$test_root/objects/$REGISTERED_DIGEST"
}

reset_objects() {
  rm -rf -- "$test_root/objects"
  mkdir -p "$test_root/objects"
  object_counter=0
}

build_fixture() {
  local revision_mode="$1"
  local index_mode="$2"
  local config_content config_digest config_size manifest_content
  local manifest_digest manifest_size index_content

  reset_objects
  case "$revision_mode" in
    present)
      config_content='{"architecture":"amd64","os":"linux","config":{"Labels":{"org.opencontainers.image.revision":"1111111111111111111111111111111111111111"}}}'
      ;;
    wrong)
      config_content='{"architecture":"amd64","os":"linux","config":{"Labels":{"org.opencontainers.image.revision":"2222222222222222222222222222222222222222"}}}'
      ;;
    missing)
      config_content='{"architecture":"amd64","os":"linux","config":{"Labels":{}}}'
      ;;
    *) fail "Unknown fixture revision mode: $revision_mode" ;;
  esac
  register_object "$config_content"
  config_digest="$REGISTERED_DIGEST"
  config_size="$REGISTERED_SIZE"

  manifest_content="$(printf '%s' '{"schemaVersion":2,"mediaType":"application/vnd.oci.image.manifest.v1+json","config":{"mediaType":"application/vnd.oci.image.config.v1+json","digest":"'"$config_digest"'","size":'"$config_size"'},"layers":[]}')"
  register_object "$manifest_content"
  manifest_digest="$REGISTERED_DIGEST"
  manifest_size="$REGISTERED_SIZE"

  case "$index_mode" in
    valid)
      index_content="$(printf '%s' '{"schemaVersion":2,"mediaType":"application/vnd.oci.image.index.v1+json","manifests":[{"mediaType":"application/vnd.oci.image.manifest.v1+json","digest":"'"$manifest_digest"'","size":'"$manifest_size"',"platform":{"os":"linux","architecture":"amd64"}},{"mediaType":"application/vnd.oci.image.manifest.v1+json","digest":"'"$manifest_digest"'","size":'"$manifest_size"',"platform":{"os":"linux","architecture":"arm64","variant":"v8"}},{"mediaType":"application/vnd.oci.image.manifest.v1+json","digest":"sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd","size":1,"platform":{"os":"unknown","architecture":"unknown"},"annotations":{"vnd.docker.reference.type":"attestation-manifest","vnd.docker.reference.digest":"'"$manifest_digest"'"}}]}')"
      ;;
    partial-platform)
      index_content="$(printf '%s' '{"schemaVersion":2,"mediaType":"application/vnd.oci.image.index.v1+json","manifests":[{"mediaType":"application/vnd.oci.image.manifest.v1+json","digest":"'"$manifest_digest"'","size":'"$manifest_size"',"platform":{"os":"linux"}}]}')"
      ;;
    no-platform)
      index_content="$(printf '%s' '{"schemaVersion":2,"mediaType":"application/vnd.oci.image.index.v1+json","manifests":[{"mediaType":"application/vnd.oci.image.manifest.v1+json","digest":"'"$manifest_digest"'","size":'"$manifest_size"'}]}')"
      ;;
    unknown-unannotated)
      index_content="$(printf '%s' '{"schemaVersion":2,"mediaType":"application/vnd.oci.image.index.v1+json","manifests":[{"mediaType":"application/vnd.oci.image.manifest.v1+json","digest":"'"$manifest_digest"'","size":'"$manifest_size"',"platform":{"os":"linux","architecture":"amd64"}},{"mediaType":"application/vnd.oci.image.manifest.v1+json","digest":"sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee","size":1,"platform":{"os":"unknown","architecture":"unknown"}}]}')"
      ;;
    unattached-attestation)
      index_content="$(printf '%s' '{"schemaVersion":2,"mediaType":"application/vnd.oci.image.index.v1+json","manifests":[{"mediaType":"application/vnd.oci.image.manifest.v1+json","digest":"'"$manifest_digest"'","size":'"$manifest_size"',"platform":{"os":"linux","architecture":"amd64"}},{"mediaType":"application/vnd.oci.image.manifest.v1+json","digest":"sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff","size":1,"platform":{"os":"unknown","architecture":"unknown"},"annotations":{"vnd.docker.reference.type":"attestation-manifest","vnd.docker.reference.digest":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}}]}')"
      ;;
    wrong-size)
      index_content="$(printf '%s' '{"schemaVersion":2,"mediaType":"application/vnd.oci.image.index.v1+json","manifests":[{"mediaType":"application/vnd.oci.image.manifest.v1+json","digest":"'"$manifest_digest"'","size":'"$((manifest_size + 1))"',"platform":{"os":"linux","architecture":"amd64"}}]}')"
      ;;
    single) index_content='' ;;
    *) fail "Unknown fixture index mode: $index_mode" ;;
  esac

  if [ "$index_mode" = single ]; then
    PLATFORM_DIGEST="$manifest_digest"
  else
    register_object "$index_content"
    PLATFORM_DIGEST="$REGISTERED_DIGEST"
  fi
  SIGNAL_DIGEST="$manifest_digest"
  BILLING_DIGEST="$manifest_digest"
}

release_payload() {
  local platform_commit="$1"
  local platform_repository="${2:-ghcr.io/apollo-deploy/apollo-platform-api}"

  printf '%s' '{"credentials":{"username":"apollo-test","token":"registry-test-token"},"releases":{"platform":{"image":"'"$platform_repository"'@'"$PLATFORM_DIGEST"'","source_commit":"'"$platform_commit"'"},"signal":{"image":"ghcr.io/apollo-deploy/apollo-signal-api@'"$SIGNAL_DIGEST"'","source_commit":"1111111111111111111111111111111111111111"},"billing":{"image":"ghcr.io/apollo-deploy/apollo-billing-api@'"$BILLING_DIGEST"'","source_commit":"1111111111111111111111111111111111111111"}}}'
}

set_cosign_mode() {
  printf '%s\n' "$1" > "$test_root/cosign-mode"
  : > "$test_root/cosign-invocations"
}

expect_verifier_failure() {
  local description="$1"
  local expected_message="$2"
  local output

  if output="$({ release_payload 1111111111111111111111111111111111111111 | /bin/bash "$verifier"; } 2>&1)"; then
    fail "$description was accepted."
  fi
  case "$output" in
    *"$expected_message"*) ;;
    *) fail "$description did not fail with a useful error: $output" ;;
  esac
}

export APOLLO_PROVENANCE_OBJECTS="$test_root/objects"
export PATH="$test_root/bin:$PATH"

build_fixture present valid
set_cosign_mode valid
release_payload 1111111111111111111111111111111111111111 \
  | /bin/bash "$verifier" >/dev/null \
  || fail 'A controlled digest/signature/SLSA-provenance fixture was rejected.'
[ "$(wc -l < "$test_root/cosign-invocations" | tr -d ' ')" = 6 ] \
  || fail 'The valid fixture did not verify both signature and provenance for all services.'

build_fixture present partial-platform
set_cosign_mode valid
expect_verifier_failure 'An incomplete platform descriptor' 'contains an incomplete, unknown, or unrecognized descriptor'

build_fixture present no-platform
set_cosign_mode valid
expect_verifier_failure 'A descriptor without a platform' 'contains an incomplete, unknown, or unrecognized descriptor'

build_fixture present unknown-unannotated
set_cosign_mode valid
expect_verifier_failure 'An unannotated unknown-platform descriptor' 'contains an incomplete, unknown, or unrecognized descriptor'

build_fixture present unattached-attestation
set_cosign_mode valid
expect_verifier_failure 'An attestation descriptor not bound to a runnable sibling' 'contains an incomplete, unknown, or unrecognized descriptor'

build_fixture present wrong-size
set_cosign_mode valid
expect_verifier_failure 'A runnable descriptor with a false byte size' 'with size'

build_fixture wrong valid
set_cosign_mode valid
expect_verifier_failure 'A digest/source revision-label mismatch' 'but the saved plan claims'

build_fixture missing valid
set_cosign_mode valid
expect_verifier_failure 'An image config without revision consistency metadata' 'has no full org.opencontainers.image.revision label'

build_fixture present valid
set_cosign_mode unsigned
expect_verifier_failure 'An unsigned image carrying a matching revision label' 'has no valid keyless signature'

set_cosign_mode forged-label
expect_verifier_failure 'A forged matching label without a trusted signer' 'has no valid keyless signature'

set_cosign_mode missing-attestation
expect_verifier_failure 'A signed image without SLSA build provenance' 'has no valid SLSA v1 provenance'

set_cosign_mode forged-provenance
expect_verifier_failure 'Cryptographically signed provenance claiming another source commit' 'signed provenance does not bind the exact subject, source, workflow, ref, and commit'

for claim_mode in wrong-issuer wrong-repository wrong-workflow wrong-ref wrong-commit; do
  set_cosign_mode "$claim_mode"
  expect_verifier_failure "A signature with $claim_mode identity" 'has no valid keyless signature'
done

set_cosign_mode valid
arbitrary_namespace_output="$({
  release_payload 1111111111111111111111111111111111111111 \
    'ghcr.io/attacker/apollo-platform-api' \
    | /bin/bash "$verifier"
} 2>&1)" && fail 'An attacker-owned lookalike repository was accepted.'
case "$arbitrary_namespace_output" in
  *'must be exactly ghcr.io/apollo-deploy/apollo-platform-api'*) ;;
  *) fail "The attacker-owned namespace did not fail clearly: $arbitrary_namespace_output" ;;
esac

nested_namespace_output="$({
  release_payload 1111111111111111111111111111111111111111 \
    'ghcr.io/apollo-deploy/nested/apollo-platform-api' \
    | /bin/bash "$verifier"
} 2>&1)" && fail 'A nested lookalike repository was accepted.'
case "$nested_namespace_output" in
  *'must be exactly ghcr.io/apollo-deploy/apollo-platform-api'*) ;;
  *) fail "The nested namespace did not fail clearly: $nested_namespace_output" ;;
esac

echo 'Release provenance verification regression tests passed.'
