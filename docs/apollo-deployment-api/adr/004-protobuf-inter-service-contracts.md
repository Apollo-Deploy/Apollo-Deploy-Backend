# ADR 004: Protobuf inter-service contracts

**Status:** Proposed  
**Date:** 2026-07-18

## Context

Kotlin control plane, Zig agents, and future runtimes must share stable, evolvable message shapes. Ad-hoc JSON payloads drift quickly and complicate deduplication and schema validation.

## Decision

All Kotlin ↔ Zig communication uses versioned Protobuf in `schemas/protobuf/`.

Conventions:

- Package: `apollo.deploy.v1`
- Shared command and event envelopes (`envelope.proto`).
- Domain payloads in focused files (`build.proto`, `agent.proto`, …).
- Breaking changes increment type suffix (`build.started.v2`) or add optional fields with new field numbers.
- Never reuse a field number within a message.
- JSON fixtures in `schemas/fixtures/` mirror serialized payloads for cross-language tests.

Public REST APIs use **JSON** (Google AIP conventions). Protobuf is for the NATS command/event bus only.

### Toolchain

| Layer | Library / tool |
|-------|----------------|
| Schema lint / breaking | [Buf CLI](https://buf.build) |
| Kotlin codegen | [protobuf-gradle-plugin](https://github.com/google/protobuf-gradle-plugin) |
| Kotlin runtime | protobuf-java + protobuf-kotlin |
| JSON interop | `protobuf-java-util` (`JsonFormat`) |
| Zig (Phase 1+) | `protoc` generated stubs from the same `.proto` files |

Generated code lives in `kotlin/proto/build/generated/` and is produced at build time — not committed.

## Consequences

### Positive

- Kotlin uses Google's official runtime — no custom serializers.
- Kotlin and Zig codegen from one source of truth.
- Uniform envelope fields (`command_id`, `correlation_id`, `desired_generation`).

### Negative

- Proto changes require coordinated releases of control plane and agents.
- Minimum supported agent version must be recorded when commands evolve.

## Follow-ups

- Phase 1: Zig `protoc` generation and fixture parsing in `zig/common/`.
- Wire `:kotlin:proto` into NATS handlers when messaging is implemented.
