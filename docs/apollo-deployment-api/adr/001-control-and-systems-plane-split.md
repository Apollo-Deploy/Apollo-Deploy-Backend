# ADR 001: Control plane vs systems plane split

**Status:** Proposed  
**Date:** 2026-07-18

## Context

Apollo Deploy orchestrates customer builds and workloads on shared infrastructure. Operators need durable deployment state, auditable transitions, and safe host-level execution without coupling business rules to machine operations.

## Decision

Split the platform into two planes with a strict boundary:

| Plane | Language | Owns |
|-------|----------|------|
| **Control plane** | Kotlin | Deployment intent, REST APIs, workflows, deployment DB state, K8s reconciliation policy |
| **Systems plane** | Zig | Host-level execution: builds, node health, local buffering, BuildKit supervision |

**Core rule:** Kotlin decides what should exist. Zig performs host-level work and reports observed outcomes.

Neither plane imports the other's internal domain models. Cross-plane communication uses versioned Protobuf over NATS (ADR 005, ADR 004).

Auth, organizations, and platform settings remain on **Apollo Platform API** — not in the deployment control plane database (ADR 003).

## Consequences

### Positive

- Business rules stay testable in Kotlin without hardware dependencies.
- Build executors upgrade independently with agent version gates.
- Customer build code blast radius is limited to isolated build nodes.

### Negative

- Every host operation requires an explicit command/event contract.
- Generation-based staleness checks are mandatory on both sides.
- Local dev requires containerized dependencies plus cloud registry and object storage.

## Follow-ups

- Phase 1: Kotlin and Zig exchange protocol fixtures.
- Phase 4: Zig host agent registers capacity and reports health.
