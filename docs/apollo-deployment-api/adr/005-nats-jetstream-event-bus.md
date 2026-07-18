# ADR 005: NATS JetStream event bus

**Status:** Proposed  
**Date:** 2026-07-18

## Context

The control plane must dispatch build commands to Zig executors and consume async events (build progress, agent health) with at-least-once delivery, replay for debugging, and horizontal consumer scaling.

## Decision

Use **NATS JetStream** as the command and event bus between Kotlin and Zig:

- Commands: Kotlin → Zig (build assign, cancel, …).
- Events: Zig → Kotlin (build started, log line, completed, agent registered, …).
- Payloads: Protobuf serialized bytes (ADR 004).
- Subjects and stream layout documented in `docs/12-protocols-and-events.md`.

Local dev: single NATS container with JetStream enabled (`make dev`, port **4222**).

## Consequences

### Positive

- Lightweight compared to Kafka for MVP scale.
- JetStream provides persistence, consumer groups, and replay.
- Decouples Kotlin workflow steps from Zig execution latency.

### Negative

- Operational expertise required for stream retention and cluster sizing in production.
- At-least-once delivery requires idempotent handlers and deduplication keys.

## Follow-ups

- Phase 1: `kotlin/messaging` publishers and consumers with envelope validation.
- Phase 2: Dead-letter and replay tooling for failed events.
