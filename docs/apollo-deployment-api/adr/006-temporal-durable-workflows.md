# ADR 006: Temporal for durable workflows

**Status:** Proposed  
**Date:** 2026-07-18

## Context

Deploy, rollback, and domain-provisioning flows span minutes, involve retries, and must survive process restarts. In-process orchestration loses state on crash and complicates cancellation.

## Decision

Use **Temporal** for durable deployment workflows:

- Workflows: build → release → deploy → verify → activate route; rollback; app deletion.
- Activities: call NATS, update deployment Postgres, apply K8s resources, poll health.
- Worker runs **in-process** in the modular monolith (ADR 002) until split is justified.
- Task queue: `apollo-deploy`.

Local dev:

- Temporal server in `make dev` (port **7233**), backed by deployment Postgres.
- **No Temporal UI** in local stack — use `tctl` or Temporal Cloud in staging.

## Consequences

### Positive

- Automatic retries, timers, and saga-style compensation.
- Workflow history is inspectable for support and debugging.
- Same workflow code when worker is later extracted to a separate deployable.

### Negative

- Additional infrastructure to operate in production.
- Workflow code must be deterministic; side effects belong in activities only.

## Follow-ups

- Phase 2: First `DeployApplicationWorkflow` with stub activities.
- Phase 6: SLI dashboards on workflow completion latency and failure rate.
