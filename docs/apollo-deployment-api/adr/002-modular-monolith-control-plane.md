# ADR 002: Modular monolith control plane

**Status:** Proposed  
**Date:** 2026-07-18

## Context

Early designs listed many Kotlin services (`platform-api`, `deployment-worker`, `build-coordinator`, …). Separate JVMs add local dev overhead without benefit before scale is proven.

## Decision

Ship the Kotlin control plane as a **modular monolith**:

| Now | Later (when scale demands) |
|-----|----------------------------|
| Single process: `apps/control-plane` | Extract workers by Gradle module boundary |
| One container / one deployable in early prod | Same modules, different `main()` or deployment target |

**In-process roles** (same JVM, separate thread pools):

- HTTP API — public REST and internal routes
- Temporal worker — workflow and activity pollers
- NATS consumers — build and agent event handlers
- Runtime reconciler — periodic Kubernetes reconcile loop

**Gradle modules** (future service boundaries):

```text
kotlin/domain, proto, persistence, temporal, messaging, kubernetes, security, observability
apps/control-plane   # composition root
```

Module rules:

- `domain` has no I/O dependencies.
- Infrastructure modules depend on `domain` only.
- `apps/control-plane` wires modules at startup.

Do **not** create separate deployables until metrics show CPU, memory, or poll-latency isolation is required.

## Consequences

### Positive

- One `make run` for local and early production.
- Clear extraction path — modules already match future service boundaries.
- Shared connection pools and configuration.

### Negative

- API and worker scaling are coupled until split.
- A process crash affects all control-plane roles (mitigate with fast restart).

## Follow-ups

- Phase 1: Ktor HTTP server + Temporal worker pool in `apps/control-plane`.
- Phase 4+: optional split of Temporal worker if poll latency suffers.
