#!/usr/bin/env bash

# Fail before production database access unless migrations come from the exact
# clean source commits reviewed beside the immutable application image digests.
set -euo pipefail

if [ "$#" -ne 9 ]; then
  echo "Usage: $0 <service> <checkout> <commit> [<service> <checkout> <commit> ...]" >&2
  exit 2
fi

command -v git >/dev/null 2>&1 || {
  echo "ERROR: Required command is unavailable: git" >&2
  exit 1
}

while [ "$#" -gt 0 ]; do
  service="$1"
  checkout="$2"
  expected_commit="$3"
  shift 3

  case "$service" in
    platform|signal|billing) ;;
    *)
      echo "ERROR: Unsupported release service: $service" >&2
      exit 1
      ;;
  esac
  if [[ ! "$expected_commit" =~ ^[0-9a-f]{40}$ ]]; then
    echo "ERROR: The $service release source commit is not a full lowercase Git object ID." >&2
    exit 1
  fi
  if ! actual_commit="$(git -C "$checkout" rev-parse --verify HEAD 2>/dev/null)"; then
    echo "ERROR: The $service source checkout is not a readable Git worktree: $checkout" >&2
    exit 1
  fi
  if [ "$actual_commit" != "$expected_commit" ]; then
    echo "ERROR: The $service checkout is at $actual_commit, but the immutable release manifest requires $expected_commit." >&2
    exit 1
  fi
  worktree_status="$(git -C "$checkout" status --porcelain --untracked-files=all)" \
    || {
      echo "ERROR: Could not inspect the $service release checkout." >&2
      exit 1
    }
  if [ -n "$worktree_status" ]; then
    unset worktree_status
    echo "ERROR: The $service checkout contains tracked or untracked changes. Commit and review the exact release source before any production database operation." >&2
    exit 1
  fi
  unset worktree_status actual_commit
done

echo "==> Immutable release commits match three clean service checkouts."
