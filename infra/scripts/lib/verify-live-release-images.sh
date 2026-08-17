#!/usr/bin/env bash

# Prove that each running production container uses the local image object
# resolved by its reviewed immutable repository digest. This deliberately uses
# Docker's image identity and RepoDigests, never caller-injected labels.
set -euo pipefail

if [ "$#" -ne 9 ]; then
  echo "Usage: $0 <service> <container> <image> [<service> <container> <image> ...]" >&2
  exit 2
fi

command -v docker >/dev/null 2>&1 || {
  echo "ERROR: Docker is unavailable for live release verification." >&2
  exit 1
}
docker info >/dev/null 2>&1 || {
  echo "ERROR: Docker is not reachable for live release verification." >&2
  exit 1
}

while [ "$#" -gt 0 ]; do
  service="$1"
  container="$2"
  expected_image="$3"
  shift 3

  case "$service:$container" in
    platform:apollo-platform|signal:apollo-signal|billing:apollo-billing) ;;
    *)
      echo "ERROR: Unsupported live release binding: $service/$container" >&2
      exit 1
      ;;
  esac
  repository="${expected_image%@sha256:*}"
  digest="sha256:${expected_image##*@sha256:}"
  if [ "$repository" != "ghcr.io/apollo-deploy/apollo-${service}-api" ] \
    || [[ ! "$digest" =~ ^sha256:[0-9a-f]{64}$ ]]; then
    echo "ERROR: $service does not use its exact allowlisted Apollo GHCR sha256 reference." >&2
    exit 1
  fi

  if ! container_image_id="$(docker container inspect --format '{{.Image}}' "$container" 2>/dev/null)"; then
    echo "ERROR: Expected live release container is missing: $container" >&2
    exit 1
  fi
  if [[ ! "$container_image_id" =~ ^sha256:[0-9a-f]{64}$ ]]; then
    echo "ERROR: $container has no valid immutable Docker image ID." >&2
    exit 1
  fi
  if ! expected_image_id="$(docker image inspect --format '{{.Id}}' "$expected_image" 2>/dev/null)"; then
    echo "ERROR: The reviewed image reference is not present on the VPS: $expected_image" >&2
    exit 1
  fi
  if [ "$container_image_id" != "$expected_image_id" ]; then
    echo "ERROR: $container runs image ID $container_image_id, not the reviewed digest's image ID $expected_image_id." >&2
    exit 1
  fi
  if ! repo_digests="$(docker image inspect --format '{{range .RepoDigests}}{{println .}}{{end}}' "$container_image_id" 2>/dev/null)"; then
    echo "ERROR: Could not inspect repository digests for $container_image_id." >&2
    exit 1
  fi
  digest_matched=false
  while IFS= read -r repo_digest; do
    if [ "$repo_digest" = "$expected_image" ]; then
      digest_matched=true
    fi
  done <<EOF
$repo_digests
EOF
  unset repo_digests
  if ! $digest_matched; then
    echo "ERROR: $container's image ID is not bound to the reviewed repository digest $expected_image." >&2
    exit 1
  fi
  echo "==> $container runs its reviewed immutable repository digest."
done
