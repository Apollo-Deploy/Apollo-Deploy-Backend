#!/usr/bin/env bash

# Verify a production release against three independent bindings:
#   1. the exact, allowlisted GHCR repository digest and every runnable config;
#   2. a keyless Sigstore signature from the governed publish workflow/ref; and
#   3. signed SLSA v1 build provenance from that same workflow and commit.
#
# The OCI revision label is deliberately only a consistency check. Registry
# credentials and bearer tokens are accepted/read through stdin or mode-0600
# files; they are never placed in child-process arguments or environment values.
set -euo pipefail
umask 077

if [ "$#" -ne 0 ]; then
  echo "Usage: $0 < release-provenance.json" >&2
  exit 2
fi

for command_name in curl jq base64 python3 cosign; do
  command -v "$command_name" >/dev/null 2>&1 || {
    echo "ERROR: Required command is unavailable: $command_name" >&2
    exit 1
  }
done

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/apollo-release-provenance.XXXXXX")"
cleanup() {
  rm -rf -- "$work_dir"
}
trap cleanup EXIT

cosign_path="$(command -v cosign)"
cosign_bin_dir="$(dirname "$cosign_path")"
cosign_home="$work_dir/cosign-home"
docker_config_dir="$work_dir/docker-config"
mkdir -p "$cosign_home" "$docker_config_dir"

# Do not let caller-provided COSIGN_*, registry, cloud, proxy, or home settings
# weaken verification. Only the path to the protected Docker config crosses the
# process boundary; the credentials themselves remain in that file.
run_cosign() {
  env -i \
    PATH="$cosign_bin_dir:/usr/bin:/bin:/usr/sbin:/sbin" \
    HOME="$cosign_home" \
    TMPDIR="$work_dir" \
    DOCKER_CONFIG="$docker_config_dir" \
    "$cosign_path" "$@"
}

if ! cosign_version_output="$(run_cosign version 2>/dev/null)"; then
  echo "ERROR: Could not determine the cosign version." >&2
  exit 1
fi
cosign_version="$(
  printf '%s\n' "$cosign_version_output" \
    | awk '$1 == "GitVersion:" { print $2; exit }'
)"
unset cosign_version_output
if [[ ! "$cosign_version" =~ ^v?3[.]([0-9]+)[.]([0-9]+)$ ]] \
  || { [ "${BASH_REMATCH[1]:-0}" -eq 0 ] && [ "${BASH_REMATCH[2]:-0}" -lt 6 ]; }; then
  echo "ERROR: cosign v3.0.6 or newer in the v3 series is required for release verification." >&2
  exit 1
fi
unset cosign_version

payload_file="$work_dir/payload.json"
cat > "$payload_file"

if ! jq -e '
  type == "object" and
  (keys == ["credentials", "releases"]) and
  (.credentials | type == "object" and keys == ["token", "username"]) and
  (.credentials.username | type == "string" and length > 0 and (test("[\\r\\n:]") | not)) and
  (.credentials.token | type == "string" and length > 0 and (test("[\\r\\n]") | not)) and
  (.releases | type == "object" and keys == ["billing", "platform", "signal"]) and
  all(.releases | to_entries[];
    (.value | type == "object" and keys == ["image", "source_commit"]) and
    (.value.image | type == "string") and
    (.value.source_commit | type == "string" and test("^[0-9a-f]{40}$"))
  )
' "$payload_file" >/dev/null; then
  echo "ERROR: Saved-plan release provenance input has an invalid schema." >&2
  exit 1
fi

username="$(jq -er '.credentials.username' "$payload_file")"
registry_password="$(jq -er '.credentials.token' "$payload_file")"
basic_authorization="$(printf '%s' "$username:$registry_password" | base64 | tr -d '\r\n')"
unset registry_password username

# jq receives the credential through stdin, not --arg (which would expose it in
# the process list). Cosign reads this standard Docker credential file.
if ! printf '%s' "$basic_authorization" \
  | jq -Rs '{auths: {"ghcr.io": {auth: .}}}' \
  > "$docker_config_dir/config.json"; then
  echo "ERROR: Could not create the protected temporary GHCR credential file." >&2
  exit 1
fi
chmod 600 "$docker_config_dir/config.json"

sha256_file() {
  python3 - "$1" <<'PY'
import hashlib
import sys

digest = hashlib.sha256()
with open(sys.argv[1], "rb") as source:
    for chunk in iter(lambda: source.read(1024 * 1024), b""):
        digest.update(chunk)
sys.stdout.write("sha256:" + digest.hexdigest())
PY
}

registry_token_for() {
  local repository="$1"
  local token_response="$2"
  local registry_token

  if ! printf 'Authorization: Basic %s\nAccept: application/json\n' "$basic_authorization" \
    | curl --fail --silent --show-error \
        --proto '=https' \
        --connect-timeout 10 \
        --max-time 60 \
        --max-filesize 1048576 \
        --header @- \
        --get \
        --data-urlencode 'service=ghcr.io' \
        --data-urlencode "scope=repository:$repository:pull" \
        --output "$token_response" \
        'https://ghcr.io/token'; then
    echo "ERROR: GHCR authentication failed for $repository." >&2
    return 1
  fi

  if ! registry_token="$(jq -er '(.token // .access_token) | select(type == "string" and length > 0)' "$token_response")"; then
    echo "ERROR: GHCR returned no registry token for $repository." >&2
    return 1
  fi
  if [[ ! "$registry_token" =~ ^[A-Za-z0-9._~+/=-]+$ ]]; then
    unset registry_token
    echo "ERROR: GHCR returned an unsafe registry token for $repository." >&2
    return 1
  fi
  printf '%s' "$registry_token"
  unset registry_token
}

fetch_digest_json() {
  local repository="$1"
  local object_kind="$2"
  local expected_digest="$3"
  local output_file="$4"
  local registry_token="$5"
  local accept_header="$6"
  local expected_size="${7:-}"
  local actual_digest actual_size

  if ! printf 'Authorization: Bearer %s\nAccept: %s\n' "$registry_token" "$accept_header" \
    | curl --fail --silent --show-error \
        --proto '=https' \
        --connect-timeout 10 \
        --max-time 60 \
        --max-filesize 33554432 \
        --header @- \
        --output "$output_file" \
        "https://ghcr.io/v2/$repository/$object_kind/$expected_digest"; then
    echo "ERROR: Could not read $repository $object_kind $expected_digest from GHCR." >&2
    return 1
  fi

  actual_digest="$(sha256_file "$output_file")"
  if [ "$actual_digest" != "$expected_digest" ]; then
    echo "ERROR: GHCR returned $repository $object_kind content with digest $actual_digest instead of $expected_digest." >&2
    return 1
  fi
  if [ -n "$expected_size" ]; then
    actual_size="$(wc -c < "$output_file" | tr -d ' ')"
    if [ "$actual_size" != "$expected_size" ]; then
      echo "ERROR: GHCR returned $repository $object_kind $expected_digest with size $actual_size instead of $expected_size." >&2
      return 1
    fi
  fi
  if ! jq -e . "$output_file" >/dev/null; then
    echo "ERROR: GHCR returned invalid JSON for $repository $object_kind $expected_digest." >&2
    return 1
  fi
}

manifest_accept='application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json'
config_accept='application/vnd.oci.image.config.v1+json, application/vnd.docker.container.image.v1+json'

verify_image_manifest() {
  local service="$1"
  local repository="$2"
  local manifest_digest="$3"
  local expected_commit="$4"
  local registry_token="$5"
  local descriptor_media_type="${6:-}"
  local ordinal="$7"
  local descriptor_size="${8:-}"
  local manifest_file="$work_dir/$service-manifest-$ordinal.json"
  local config_file="$work_dir/$service-config-$ordinal.json"
  local media_type config_digest config_media_type config_size image_revision

  fetch_digest_json "$repository" manifests "$manifest_digest" "$manifest_file" \
    "$registry_token" "$manifest_accept" "$descriptor_size"

  media_type="$(jq -er '.mediaType | select(type == "string")' "$manifest_file")" \
    || {
      echo "ERROR: $service manifest $manifest_digest has no media type." >&2
      return 1
    }
  case "$media_type" in
    application/vnd.oci.image.manifest.v1+json|application/vnd.docker.distribution.manifest.v2+json) ;;
    *)
      echo "ERROR: $service descriptor $manifest_digest is not an image manifest ($media_type)." >&2
      return 1
      ;;
  esac
  if [ -n "$descriptor_media_type" ] && [ "$media_type" != "$descriptor_media_type" ]; then
    echo "ERROR: $service descriptor media type does not match manifest $manifest_digest." >&2
    return 1
  fi
  if ! jq -e '.schemaVersion == 2' "$manifest_file" >/dev/null; then
    echo "ERROR: $service manifest $manifest_digest is not schema version 2." >&2
    return 1
  fi

  config_digest="$(jq -er '.config.digest | select(type == "string" and test("^sha256:[0-9a-f]{64}$"))' "$manifest_file")" \
    || {
      echo "ERROR: $service manifest $manifest_digest has no pinned sha256 config." >&2
      return 1
    }
  config_media_type="$(jq -er '.config.mediaType | select(type == "string")' "$manifest_file")" \
    || {
      echo "ERROR: $service manifest $manifest_digest has no config media type." >&2
      return 1
    }
  config_size="$(jq -er '.config.size | select(type == "number" and floor == . and . > 0)' "$manifest_file")" \
    || {
      echo "ERROR: $service manifest $manifest_digest has no valid config size." >&2
      return 1
    }
  case "$config_media_type" in
    application/vnd.oci.image.config.v1+json|application/vnd.docker.container.image.v1+json) ;;
    *)
      echo "ERROR: $service manifest $manifest_digest uses an unsupported config media type ($config_media_type)." >&2
      return 1
      ;;
  esac

  fetch_digest_json "$repository" blobs "$config_digest" "$config_file" \
    "$registry_token" "$config_accept" "$config_size"
  if ! image_revision="$(jq -er '.config.Labels["org.opencontainers.image.revision"] | select(type == "string" and test("^[0-9a-f]{40}$"))' "$config_file")"; then
    echo "ERROR: $service image config $config_digest has no full org.opencontainers.image.revision label." >&2
    return 1
  fi
  if [ "$image_revision" != "$expected_commit" ]; then
    echo "ERROR: $service image config $config_digest was built from $image_revision, but the saved plan claims $expected_commit." >&2
    return 1
  fi
}

verify_signed_provenance() {
  local service="$1"
  local image_reference="$2"
  local expected_commit="$3"
  local source_repository workflow_ref workflow_identity signature_output attestation_output
  local subject_repository subject_digest source_url source_uri
  local -a certificate_policy

  case "$service" in
    platform)
      source_repository='Apollo-Deploy/Apollo-Platform-API'
      workflow_ref='refs/heads/main'
      ;;
    signal)
      source_repository='Apollo-Deploy/Apollo-Signal-API'
      workflow_ref='refs/heads/development'
      ;;
    billing)
      source_repository='Apollo-Deploy/Apollo-Billing-API'
      workflow_ref='refs/heads/main'
      ;;
    *)
      echo "ERROR: Unsupported release service: $service" >&2
      return 1
      ;;
  esac

  workflow_identity="https://github.com/$source_repository/.github/workflows/docker-publish.yml@$workflow_ref"
  certificate_policy=(
    --certificate-oidc-issuer 'https://token.actions.githubusercontent.com'
    --certificate-identity "$workflow_identity"
    --certificate-github-workflow-repository "$source_repository"
    --certificate-github-workflow-ref "$workflow_ref"
    --certificate-github-workflow-sha "$expected_commit"
    --certificate-github-workflow-trigger 'push'
    --timeout 2m
    --output json
  )

  signature_output="$work_dir/$service-signatures.json"
  if ! run_cosign verify "${certificate_policy[@]}" "$image_reference" > "$signature_output"; then
    echo "ERROR: $service release has no valid keyless signature from its governed workflow, ref, and commit." >&2
    return 1
  fi
  if ! jq -s -e 'length > 0' "$signature_output" >/dev/null; then
    echo "ERROR: $service keyless signature verification returned no valid evidence." >&2
    return 1
  fi

  attestation_output="$work_dir/$service-provenance.json"
  if ! run_cosign verify-attestation \
    --type slsaprovenance1 \
    "${certificate_policy[@]}" \
    "$image_reference" > "$attestation_output"; then
    echo "ERROR: $service release has no valid SLSA v1 provenance from its governed workflow, ref, and commit." >&2
    return 1
  fi
  if ! jq -s -e 'length > 0' "$attestation_output" >/dev/null; then
    echo "ERROR: $service SLSA provenance verification returned no valid evidence." >&2
    return 1
  fi

  subject_repository="${image_reference%@sha256:*}"
  subject_digest="${image_reference##*@sha256:}"
  source_url="https://github.com/$source_repository"
  source_uri="git+$source_url@$workflow_ref"
  if ! jq -s -e \
    --arg subject_repository "$subject_repository" \
    --arg subject_digest "$subject_digest" \
    --arg source_url "$source_url" \
    --arg source_uri "$source_uri" \
    --arg source_commit "$expected_commit" \
    --arg source_ref "$workflow_ref" \
    --arg builder_id "$workflow_identity" '
      [
        .[] |
        (if type == "array" then .[] else . end) |
        select(.payload? | type == "string") |
        try (.payload | @base64d | fromjson)
      ] as $statements |
      any($statements[];
        # Cosign v3.0.6 constructs this v0.1 in-toto envelope from the
        # explicitly typed SLSA v1 predicate. Treat a future envelope change as
        # a reviewed verifier upgrade, not as an implicit compatibility path.
        ._type == "https://in-toto.io/Statement/v0.1" and
        .predicateType == "https://slsa.dev/provenance/v1" and
        .subject == [{name: $subject_repository, digest: {sha256: $subject_digest}}] and
        .predicate.buildDefinition.buildType == "https://actions.github.io/buildtypes/workflow/v1" and
        .predicate.buildDefinition.externalParameters.workflow == {
          repository: $source_url,
          ref: $source_ref,
          path: ".github/workflows/docker-publish.yml"
        } and
        .predicate.buildDefinition.internalParameters == {github: {eventName: "push"}} and
        .predicate.buildDefinition.resolvedDependencies == [{
          uri: $source_uri,
          digest: {gitCommit: $source_commit}
        }] and
        .predicate.runDetails.builder == {id: $builder_id} and
        (.predicate.runDetails.metadata.invocationId |
          type == "string" and
          test("^" + ($source_url | gsub("[.]"; "\\.")) + "/actions/runs/[0-9]+/attempts/[0-9]+$"))
      )
    ' "$attestation_output" >/dev/null; then
    echo "ERROR: $service signed provenance does not bind the exact subject, source, workflow, ref, and commit." >&2
    return 1
  fi
}

classify_index_descriptors() {
  local index_file="$1"
  local output_file="$2"

  # One fail-closed classifier owns the entire index decision. A descriptor is
  # runnable only with a complete concrete platform and valid OCI descriptor
  # fields. The sole ignored class is Docker/BuildKit's explicit
  # attestation-manifest convention, and it must point at a runnable sibling.
  jq -c '
    def sha256_digest:
      type == "string" and test("^sha256:[0-9a-f]{64}$");
    def positive_integer:
      type == "number" and floor == . and . > 0;
    def image_manifest_media_type:
      . == "application/vnd.oci.image.manifest.v1+json" or
      . == "application/vnd.docker.distribution.manifest.v2+json";
    def base_descriptor:
      type == "object" and
      (.digest | sha256_digest) and
      (.size | positive_integer) and
      (.mediaType | image_manifest_media_type);
    def concrete_platform:
      (.platform | type == "object") and
      (.platform.os | type == "string" and test("^[a-z0-9][a-z0-9._-]*$") and . != "unknown") and
      (.platform.architecture | type == "string" and test("^[a-z0-9][a-z0-9._-]*$") and . != "unknown") and
      ((.platform.variant == null) or
       (.platform.variant | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9._-]*$")));
    def runnable:
      base_descriptor and concrete_platform;
    def recognized_attestation($runnable_digests):
      . as $descriptor |
      base_descriptor and
      (.mediaType == "application/vnd.oci.image.manifest.v1+json") and
      (.platform | type == "object" and keys == ["architecture", "os"]) and
      (.platform.os == "unknown") and
      (.platform.architecture == "unknown") and
      (.annotations | type == "object") and
      (.annotations["vnd.docker.reference.type"] == "attestation-manifest") and
      (.annotations["vnd.docker.reference.digest"] | sha256_digest) and
      (($runnable_digests | index($descriptor.annotations["vnd.docker.reference.digest"])) != null);

    (.manifests | map(select(runnable) | .digest)) as $runnable_digests |
    .manifests[] |
    if runnable then
      {class: "runnable", digest, mediaType, size}
    elif recognized_attestation($runnable_digests) then
      {class: "attestation"}
    else
      {class: "invalid"}
    end
  ' "$index_file" > "$output_file"
}

verify_release() {
  local service="$1"
  local expected_repository image expected_commit reference repository top_digest
  local registry_token token_response top_manifest media_type classifications
  local descriptor_record descriptor_class child_digest child_media_type child_size
  local runnable_descriptors ordinal

  expected_repository="apollo-deploy/apollo-$service-api"
  image="$(jq -er --arg service "$service" '.releases[$service].image' "$payload_file")"
  expected_commit="$(jq -er --arg service "$service" '.releases[$service].source_commit' "$payload_file")"

  if [[ ! "$image" =~ ^ghcr[.]io/${expected_repository}@sha256:[0-9a-f]{64}$ ]]; then
    echo "ERROR: $service release image must be exactly ghcr.io/$expected_repository at a lowercase sha256 digest." >&2
    return 1
  fi
  reference="${image#ghcr.io/}"
  repository="${reference%@sha256:*}"
  top_digest="sha256:${reference##*@sha256:}"

  token_response="$work_dir/$service-token.json"
  registry_token="$(registry_token_for "$repository" "$token_response")"
  top_manifest="$work_dir/$service-top-manifest.json"
  fetch_digest_json "$repository" manifests "$top_digest" "$top_manifest" \
    "$registry_token" "$manifest_accept"
  media_type="$(jq -er '.mediaType | select(type == "string")' "$top_manifest")" \
    || {
      unset registry_token
      echo "ERROR: $service top-level digest has no media type." >&2
      return 1
    }

  case "$media_type" in
    application/vnd.oci.image.manifest.v1+json|application/vnd.docker.distribution.manifest.v2+json)
      verify_image_manifest "$service" "$repository" "$top_digest" \
        "$expected_commit" "$registry_token" "$media_type" 0
      ;;
    application/vnd.oci.image.index.v1+json|application/vnd.docker.distribution.manifest.list.v2+json)
      if ! jq -e '
        .schemaVersion == 2 and
        (.manifests | type == "array" and length > 0)
      ' "$top_manifest" >/dev/null; then
        unset registry_token
        echo "ERROR: $service image index $top_digest is malformed." >&2
        return 1
      fi

      classifications="$work_dir/$service-descriptor-classes.jsonl"
      if ! classify_index_descriptors "$top_manifest" "$classifications"; then
        unset registry_token
        echo "ERROR: $service image index $top_digest could not be classified safely." >&2
        return 1
      fi
      runnable_descriptors="$work_dir/$service-runnable-descriptors.tsv"
      : > "$runnable_descriptors"
      while IFS= read -r descriptor_record; do
        descriptor_class="$(printf '%s' "$descriptor_record" | jq -er '.class')"
        case "$descriptor_class" in
          runnable)
            printf '%s\n' "$descriptor_record" \
              | jq -r '[.digest, .mediaType, (.size | tostring)] | @tsv' \
              >> "$runnable_descriptors"
            ;;
          attestation) ;;
          *)
            unset registry_token
            echo "ERROR: $service image index $top_digest contains an incomplete, unknown, or unrecognized descriptor." >&2
            return 1
            ;;
        esac
      done < "$classifications"

      if [ ! -s "$runnable_descriptors" ]; then
        unset registry_token
        echo "ERROR: $service image index $top_digest has no runnable platform manifests." >&2
        return 1
      fi
      ordinal=0
      while IFS="$(printf '\t')" read -r child_digest child_media_type child_size; do
        ordinal=$((ordinal + 1))
        verify_image_manifest "$service" "$repository" "$child_digest" \
          "$expected_commit" "$registry_token" "$child_media_type" "$ordinal" "$child_size"
      done < "$runnable_descriptors"
      ;;
    *)
      unset registry_token
      echo "ERROR: $service top-level digest is not an OCI/Docker image manifest or index ($media_type)." >&2
      return 1
      ;;
  esac
  unset registry_token

  verify_signed_provenance "$service" "$image" "$expected_commit"
  echo "==> $service digest, keyless signature, provenance, and revision consistency are verified."
}

for service in platform signal billing; do
  verify_release "$service"
done

unset basic_authorization
echo "==> Exact GHCR digests have trusted signatures and SLSA provenance for all reviewed commits."
