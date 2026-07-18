# ADR 010: Cloud OCI registry

**Status:** Proposed  
**Date:** 2026-07-18

## Context

Releases must pin **immutable image digests**. A local `registry:2` container diverges from production push/pull flows and adds garbage-collection overhead.

## Decision

- **No local registry container** in `make dev`.
- Dev, staging, and production push to a **cloud OCI registry** (default: **GHCR** via `APOLLO_DEPLOY_REGISTRY`).
- BuildKit on Zig executors push to the configured registry; Kotlin stores `image_digest` on the release.
- Local development requires registry credentials in `.env` (or CI OIDC to GHCR).

## Consequences

### Positive

- Same code path as production.
- One fewer local container.
- Digest-pinned releases from day one.

### Negative

- Requires network and credentials for image push even locally.
- Slightly slower iteration than a localhost registry (acceptable).

## Follow-ups

- Phase 3: Short-lived registry credentials scoped per build.
- Document GHCR package naming convention per organization.
