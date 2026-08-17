#!/usr/bin/env bash

set -euo pipefail

test_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$test_dir/../../.." && pwd)"
verifier="$repo_root/infra/scripts/lib/verify-live-release-images.sh"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/apollo-live-release-tests.XXXXXX")"

cleanup() {
  rm -rf -- "$test_root"
}
trap cleanup EXIT

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

mkdir -p "$test_root/bin"
cat > "$test_root/bin/docker" <<'DOCKER'
#!/usr/bin/env bash
set -euo pipefail

case "$1 ${2:-} ${3:-}" in
  'info  ')
    exit 0
    ;;
  'container inspect --format')
    container="$5"
    case "$container" in
      apollo-platform)
        if [ "${APOLLO_LIVE_IMAGE_SCENARIO:-match}" = mismatch ]; then
          printf '%s\n' 'sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff'
        else
          printf '%s\n' 'sha256:1111111111111111111111111111111111111111111111111111111111111111'
        fi
        ;;
      apollo-signal) printf '%s\n' 'sha256:2222222222222222222222222222222222222222222222222222222222222222' ;;
      apollo-billing) printf '%s\n' 'sha256:3333333333333333333333333333333333333333333333333333333333333333' ;;
      *) exit 1 ;;
    esac
    ;;
  'image inspect --format')
    format="$4"
    image="$5"
    case "$format" in
      '{{.Id}}')
        case "$image" in
          *apollo-platform-api@*) printf '%s\n' 'sha256:1111111111111111111111111111111111111111111111111111111111111111' ;;
          *apollo-signal-api@*) printf '%s\n' 'sha256:2222222222222222222222222222222222222222222222222222222222222222' ;;
          *apollo-billing-api@*) printf '%s\n' 'sha256:3333333333333333333333333333333333333333333333333333333333333333' ;;
          *) exit 1 ;;
        esac
        ;;
      '{{range .RepoDigests}}{{println .}}{{end}}')
        case "$image" in
          sha256:1111*) printf '%s\n' "ghcr.io/apollo-deploy/apollo-platform-api@$APOLLO_PLATFORM_DIGEST" ;;
          sha256:2222*) printf '%s\n' "ghcr.io/apollo-deploy/apollo-signal-api@$APOLLO_SIGNAL_DIGEST" ;;
          sha256:3333*) printf '%s\n' "ghcr.io/apollo-deploy/apollo-billing-api@$APOLLO_BILLING_DIGEST" ;;
          *) exit 1 ;;
        esac
        ;;
      *) exit 1 ;;
    esac
    ;;
  *)
    echo "Unexpected fake Docker invocation: $*" >&2
    exit 1
    ;;
esac
DOCKER
chmod 700 "$test_root/bin/docker"

export APOLLO_PLATFORM_DIGEST=sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
export APOLLO_SIGNAL_DIGEST=sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
export APOLLO_BILLING_DIGEST=sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
export PATH="$test_root/bin:$PATH"

verify_fixture() {
  /bin/bash "$verifier" \
    platform apollo-platform "ghcr.io/apollo-deploy/apollo-platform-api@$APOLLO_PLATFORM_DIGEST" \
    signal apollo-signal "ghcr.io/apollo-deploy/apollo-signal-api@$APOLLO_SIGNAL_DIGEST" \
    billing apollo-billing "ghcr.io/apollo-deploy/apollo-billing-api@$APOLLO_BILLING_DIGEST"
}

APOLLO_LIVE_IMAGE_SCENARIO=match verify_fixture >/dev/null \
  || fail 'Running containers with matching image IDs and RepoDigests were rejected.'

mismatch_output="$({
  APOLLO_LIVE_IMAGE_SCENARIO=mismatch verify_fixture
} 2>&1)" && fail 'A running container using a different image ID was accepted.'
case "$mismatch_output" in
  *'runs image ID '*'not the reviewed digest'*) ;;
  *) fail "Live image mismatch did not fail with a useful error: $mismatch_output" ;;
esac

for rejected_platform_image in \
  "ghcr.io/attacker/apollo-platform-api@$APOLLO_PLATFORM_DIGEST" \
  "ghcr.io/apollo-deploy/nested/apollo-platform-api@$APOLLO_PLATFORM_DIGEST"; do
  allowlist_output="$({
    /bin/bash "$verifier" \
      platform apollo-platform "$rejected_platform_image" \
      signal apollo-signal "ghcr.io/apollo-deploy/apollo-signal-api@$APOLLO_SIGNAL_DIGEST" \
      billing apollo-billing "ghcr.io/apollo-deploy/apollo-billing-api@$APOLLO_BILLING_DIGEST"
  } 2>&1)" && fail "A non-allowlisted live Platform repository was accepted: $rejected_platform_image"
  case "$allowlist_output" in
    *'does not use its exact allowlisted Apollo GHCR sha256 reference'*) ;;
    *) fail "The non-allowlisted live repository did not fail clearly: $allowlist_output" ;;
  esac
done

echo 'Live release image verification regression tests passed.'
