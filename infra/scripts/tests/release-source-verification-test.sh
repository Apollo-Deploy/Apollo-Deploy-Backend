#!/usr/bin/env bash

set -euo pipefail

test_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$test_dir/../../.." && pwd)"
verifier="$repo_root/infra/scripts/lib/verify-release-sources.sh"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/apollo-release-source-tests.XXXXXX")"

cleanup() {
  rm -rf -- "$test_root"
}
trap cleanup EXIT

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

initialize_checkout() {
  local checkout="$1"
  mkdir -p "$checkout"
  git -C "$checkout" init -q
  printf '%s\n' 'reviewed migration source' > "$checkout/source.txt"
  git -C "$checkout" add source.txt
  git -C "$checkout" \
    -c user.name='Apollo Test' \
    -c user.email='apollo-test@example.invalid' \
    commit -q -m 'test release source'
}

platform_checkout="$test_root/platform"
signal_checkout="$test_root/signal"
billing_checkout="$test_root/billing"
initialize_checkout "$platform_checkout"
initialize_checkout "$signal_checkout"
initialize_checkout "$billing_checkout"
platform_commit="$(git -C "$platform_checkout" rev-parse HEAD)"
signal_commit="$(git -C "$signal_checkout" rev-parse HEAD)"
billing_commit="$(git -C "$billing_checkout" rev-parse HEAD)"

verify_fixture() {
  /bin/bash "$verifier" \
    platform "$platform_checkout" "$platform_commit" \
    signal "$signal_checkout" "$signal_commit" \
    billing "$billing_checkout" "$billing_commit"
}

verify_fixture >/dev/null \
  || fail 'Three clean exact-commit release checkouts were rejected.'

printf '%s\n' 'dirty' >> "$platform_checkout/source.txt"
if verify_fixture >/dev/null 2>&1; then
  fail 'A tracked release-source modification was accepted.'
fi
git -C "$platform_checkout" restore source.txt

printf '%s\n' 'untracked' > "$signal_checkout/untracked.txt"
if verify_fixture >/dev/null 2>&1; then
  fail 'An untracked release-source file was accepted.'
fi
rm -f -- "$signal_checkout/untracked.txt"

wrong_commit=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
if /bin/bash "$verifier" \
  platform "$platform_checkout" "$wrong_commit" \
  signal "$signal_checkout" "$signal_commit" \
  billing "$billing_checkout" "$billing_commit" >/dev/null 2>&1; then
  fail 'A release manifest/check-out commit mismatch was accepted.'
fi

if /bin/bash "$verifier" \
  platform "$platform_checkout" short \
  signal "$signal_checkout" "$signal_commit" \
  billing "$billing_checkout" "$billing_commit" >/dev/null 2>&1; then
  fail 'A non-full release source commit was accepted.'
fi

echo 'Release source verification regression tests passed.'
