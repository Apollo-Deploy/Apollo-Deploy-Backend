# ADR 009: Cloudflare R2 for object storage

**Status:** Proposed  
**Date:** 2026-07-18

## Context

Builds require durable storage for source archives and build artifacts. Running MinIO locally adds container overhead and diverges from production S3-compatible APIs.

## Decision

Use **Cloudflare R2** (AWS S3 API) for object storage:

- Source uploads: `APOLLO_DEPLOY_S3_SOURCES_BUCKET`
- Build artifacts: `APOLLO_DEPLOY_S3_ARTIFACTS_BUCKET`
- Credentials via `APOLLO_DEPLOY_R2_*` in `.env` (see `.env.example`).
- **No local object-storage container** in `make dev`.

Kotlin generates presigned upload URLs; Zig executors fetch sources and optionally push artifacts via the S3 API.

## Consequences

### Positive

- Same code path in dev, staging, and production.
- No local MinIO volume management.
- R2 egress pricing model suits artifact storage.

### Negative

- Requires network and cloud credentials for local builds.
- Bucket lifecycle and IAM policies must be provisioned per environment.

## Follow-ups

- Phase 2: Presigned upload flow in build coordinator.
- Terraform modules for dev/staging/prod buckets.
