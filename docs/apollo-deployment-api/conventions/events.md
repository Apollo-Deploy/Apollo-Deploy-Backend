# Deployment API — event extensions

Extends the fleet-wide [event and command conventions](../../conventions/events.md) for Kotlin control-plane ↔ Zig systems-plane messaging over NATS JetStream.

Protobuf definitions: `schemas/protobuf/apollo/deploy/v1/envelope.proto`.

---

## NATS subjects

```text
apollo.commands.build.<region>     # Kotlin → Zig build dispatch
apollo.events.build                # Build lifecycle events
apollo.events.agent                # Node registration and health
apollo.events.usage                # Metering (Phase 6+)
```

See [protocols and events](../../../apollo-deployment-api/docs/12-protocols-and-events.md) for full subject catalog.

---

## Event type examples

```text
build.assigned.v1
build.started.v1
build.completed.v1
build.failed.v1
agent.heartbeat.v1
```

---

## Fixtures

Example files:

```text
schemas/fixtures/command_build_assign.v1.json
schemas/fixtures/event_build_started.v1.json
schemas/fixtures/event_agent_registered.v1.json
```

Fixtures are validated in CI against Protobuf JSON mapping.

---

## Related documents

- [Fleet event conventions](../../conventions/events.md)
- [Deployment REST extensions](api.md)
- [Protocols and events](../../../apollo-deployment-api/docs/12-protocols-and-events.md)
- [ADR 004: Protobuf contracts](../adr/004-protobuf-inter-service-contracts.md)
- [ADR 005: NATS JetStream](../adr/005-nats-jetstream-event-bus.md)
