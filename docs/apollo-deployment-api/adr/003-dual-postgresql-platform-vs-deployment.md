# ADR 003: Dual PostgreSQL — platform vs deployment

**Status:** Proposed  
**Date:** 2026-07-18

## Context

Apollo Platform already runs PostgreSQL for auth, organizations, and settings (`infra/terraform`, port **5432**). Deployment state (builds, releases, deployments, domains) has different scaling, backup, and migration lifecycles.

## Decision

Use **two PostgreSQL instances**:

| Instance | Port (local) | Owns |
|----------|--------------|------|
| **Platform Postgres** | 5432 | Users, auth, orgs, settings (Apollo Platform API) |
| **Deployment Postgres** | 5440 | Builds, releases, deployments, domains, idempotency keys |

Rules:

- Deployment API **never** stores user credentials or session data.
- AuthZ validates org ownership via Platform OAuth; deployment DB stores `organization_id` as an opaque reference only.
- Temporal persistence uses **deployment Postgres** (same instance, separate schema).
- Production: separate managed instances or clusters with independent backup policies.

Local `make dev` starts **deployment Postgres only**. Platform Postgres comes from `infra/terraform/environments/local`.

## Consequences

### Positive

- Clear blast-radius separation between auth and deployment data.
- Deployment migrations do not touch platform auth schema.
- Deployment DB can scale independently.

### Negative

- Two connection strings and backup policies to operate.
- No cross-DB joins — use Platform API for auth metadata.

## Follow-ups

- Phase 1: Flyway migrations and `kotlin/persistence` wired to deployment Postgres only.
- Document Platform API as the auth source in service configuration.
