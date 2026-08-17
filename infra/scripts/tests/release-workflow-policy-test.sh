#!/usr/bin/env bash

set -euo pipefail

test_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$test_dir/../../.." && pwd)"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/apollo-release-workflow-tests.XXXXXX")"

cleanup() {
  rm -rf -- "$test_root"
}
trap cleanup EXIT

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

assert_contains() {
  local file="$1"
  local literal="$2"
  local description="$3"

  grep -F -- "$literal" "$file" >/dev/null \
    || fail "$description ($file)"
}

check_workflow() {
  local service="$1"
  local source_repository="$2"
  local source_branch="$3"
  local workflow="$repo_root/apollo-$service-api/.github/workflows/docker-publish.yml"
  local dockerfile="$repo_root/apollo-$service-api/Dockerfile"
  local action_ref provenance_script predicate_dir predicate_file other_workflow

  [ -f "$workflow" ] || fail "Missing governed $service container workflow."
  assert_contains "$workflow" "IMAGE: ghcr.io/apollo-deploy/apollo-$service-api" \
    "$service workflow does not publish only to its allowlisted repository"
  assert_contains "$workflow" "github.repository == '$source_repository'" \
    "$service publisher is not bound to its exact source repository"
  assert_contains "$workflow" "github.ref == 'refs/heads/$source_branch'" \
    "$service publisher is not bound to its governed source ref"
  # The following workflow expressions and shell variables are intentional literals.
  # shellcheck disable=SC2016
  assert_contains "$workflow" 'BUILD_REVISION=${{ github.sha }}' \
    "$service image revision label is not sourced from the workflow commit"
  # shellcheck disable=SC2016
  assert_contains "$workflow" 'cosign sign --yes "${IMAGE}@${DIGEST}"' \
    "$service digest is not keylessly signed"
  assert_contains "$workflow" "cosign attest --help | grep -F -- '--predicate' >/dev/null" \
    "$service publisher does not check the supported predicate interface"
  assert_contains "$workflow" "cosign attest --help | grep -F -- 'slsaprovenance1' >/dev/null" \
    "$service publisher does not check the supported SLSA v1 type"
  # shellcheck disable=SC2016
  assert_contains "$workflow" 'cosign attest --yes --type slsaprovenance1 --predicate "$predicate_file" "${IMAGE}@${DIGEST}"' \
    "$service signed SLSA predicate is not published with the exact image"
  if grep -F -- '--statement' "$workflow" >/dev/null; then
    fail "$service uses Cosign v3.0.6's advertised-but-unwired image --statement option"
  fi
  assert_contains "$workflow" 'provenance: false' \
    "$service workflow did not disable the separate unsigned BuildKit provenance"

  [ "$(grep -nF -- "cosign attest --help | grep -F -- '--predicate' >/dev/null" "$workflow" | cut -d: -f1)" -lt \
    "$(grep -nF -- 'uses: docker/build-push-action@' "$workflow" | tail -n 1 | cut -d: -f1)" ] \
    || fail "$service predicate compatibility check does not run before publishing"

  while IFS= read -r action_ref; do
    [[ "$action_ref" =~ @[0-9a-f]{40}$ ]] \
      || fail "$service container workflow has a non-immutable action reference: $action_ref"
  done < <(sed -n 's/^[[:space:]]*uses:[[:space:]]*\([^[:space:]#]*\).*/\1/p' "$workflow")

  # shellcheck disable=SC2016
  assert_contains "$dockerfile" 'org.opencontainers.image.revision="${BUILD_REVISION}"' \
    "$service Dockerfile is missing revision consistency metadata"
  assert_contains "$dockerfile" "org.opencontainers.image.source=\"https://github.com/Apollo-Deploy/apollo-$service-api\"" \
    "$service Dockerfile is missing its source-repository label"

  provenance_script="$(awk '
    /^      - name: Publish keylessly signed SLSA v1 build provenance$/ {
      in_step = 1
      next
    }
    in_step && /^        run: \|$/ {
      capture = 1
      next
    }
    capture && /^          cosign attest / {
      exit
    }
    capture {
      sub(/^          /, "")
      print
    }
  ' "$workflow")"
  [ -n "$provenance_script" ] \
    || fail "$service workflow provenance generator could not be extracted"
  predicate_dir="$test_root/$service"
  mkdir -p "$predicate_dir"
  IMAGE="ghcr.io/apollo-deploy/apollo-$service-api" \
    DIGEST='sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' \
    SOURCE_COMMIT='1111111111111111111111111111111111111111' \
    SOURCE_REF="refs/heads/$source_branch" \
    SOURCE_REPOSITORY="$source_repository" \
    WORKFLOW_PATH='.github/workflows/docker-publish.yml' \
    RUN_ID=123 \
    RUN_ATTEMPT=1 \
    RUNNER_TEMP="$predicate_dir" \
    bash -c "$provenance_script"
  predicate_file="$predicate_dir/apollo-slsa-provenance.json"
  jq -e \
    --arg repository "https://github.com/$source_repository" \
    --arg ref "refs/heads/$source_branch" '
      keys == ["buildDefinition", "runDetails"] and
      .buildDefinition.buildType == "https://actions.github.io/buildtypes/workflow/v1" and
      .buildDefinition.externalParameters.workflow == {
        repository: $repository,
        ref: $ref,
        path: ".github/workflows/docker-publish.yml"
      } and
      .buildDefinition.internalParameters == {github: {eventName: "push"}} and
      .buildDefinition.resolvedDependencies == [{
        uri: ("git+" + $repository + "@" + $ref),
        digest: {gitCommit: "1111111111111111111111111111111111111111"}
      }] and
      .runDetails.builder == {
        id: ($repository + "/.github/workflows/docker-publish.yml@" + $ref)
      }
    ' "$predicate_file" >/dev/null \
    || fail "$service workflow did not generate the required SLSA v1 predicate"

  while IFS= read -r other_workflow; do
    if grep -Eq 'docker/build-push-action|cosign (sign|attest)|ghcr[.]io' "$other_workflow"; then
      fail "$service has a second container publisher outside the governed workflow: $other_workflow"
    fi
  done < <(
    find "$repo_root/apollo-$service-api/.github/workflows" \
      -maxdepth 1 -type f \( -name '*.yml' -o -name '*.yaml' \) \
      ! -name 'docker-publish.yml' -print
  )
}

check_workflow platform 'Apollo-Deploy/Apollo-Platform-API' main
check_workflow signal 'Apollo-Deploy/Apollo-Signal-API' main
check_workflow billing 'Apollo-Deploy/Apollo-Billing-API' main

[ ! -e "$repo_root/apollo-billing-api/.github/workflows/docker.yml" ] \
  || fail 'The retired unsigned Billing container publisher still exists.'

billing_release="$repo_root/apollo-billing-api/.github/workflows/release.yml"
assert_contains "$billing_release" 'permissions: {}' \
  'The Billing tag release grants write permission to every job.'
assert_contains "$billing_release" 'persist-credentials: false' \
  'The Billing tag release persists a write-capable checkout credential.'
while IFS= read -r action_ref; do
  [[ "$action_ref" =~ @[0-9a-f]{40}$ ]] \
    || fail "The write-capable Billing tag release has a non-immutable action reference: $action_ref"
done < <(sed -n 's/^[[:space:]]*uses:[[:space:]]*\([^[:space:]#]*\).*/\1/p' "$billing_release")

echo 'Release workflow policy regression tests passed.'
