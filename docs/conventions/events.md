# Event and Command Conventions

Async communication between Apollo services uses versioned message envelopes, explicit schema versions, and at-least-once delivery semantics.

Transport (NATS JetStream, webhooks, queues) is chosen per service — see project ADRs. These rules apply regardless of transport.

---

## Envelope fields

Every **command** includes:

| Field | Purpose |
|-------|---------|
| `command_id` | Idempotency key; dedupe on consumers |
| `command_type` | Stable type identifier (for example `resource.assign`) |
| `schema_version` | Contract version (`v1`) |
| `correlation_id` | End-to-end trace across workflow steps |
| `causation_id` | Parent message ID (command or event) |
| `organization_id` | Tenant boundary |
| `resource_id` | Target resource |
| `desired_generation` | Optimistic concurrency for resource (when applicable) |
| `issued_at` | UTC timestamp |
| `expires_at` | Commands ignored after expiry |
| `payload` | Typed payload (Protobuf oneof / Any recommended) |

Every **event** includes:

| Field | Purpose |
|-------|---------|
| `event_id` | Deduplication key |
| `event_type` | Stable type identifier (for example `resource.started.v1`) |
| `schema_version` | Contract version |
| `source` | Emitting service (`platform-api`, `billing-api`, …) |
| `occurred_at` | UTC timestamp |
| `correlation_id` | Matches originating workflow |
| `causation_id` | Command or prior event |
| `organization_id` | Tenant boundary |
| `resource_id` | Subject resource |
| `payload` | Typed payload |

Payloads should be defined in versioned Protobuf (or equivalent schema) and validated in CI.

---

## Event type naming

```text
<domain>.<action>.v<major>
```

Examples:

```text
resource.created.v1
resource.updated.v1
resource.deleted.v1
workflow.completed.v1
```

Minor-compatible payload changes do not bump the suffix. Breaking payload changes add `v2`.

Command types use a parallel pattern without the version suffix when the command envelope carries `schema_version`:

```text
<domain>.<action>
```

Examples: `resource.assign`, `workflow.start`.

---

## Delivery semantics

Assume **at-least-once** delivery. Consumers must handle:

- Duplicate messages (dedupe by `command_id` / `event_id`)
- Delayed and reordered messages
- Redelivery after crashes
- Expired commands (`expires_at` in the past → ack and drop)
- Stale generations (`desired_generation` < resource.current → ack and drop)

---

## Deduplication

| Message kind | Key |
|--------------|-----|
| Commands | `command_id` |
| Resource mutations | Also validate `desired_generation` when applicable |
| Events | `event_id` |

---

## Compatibility rules

- Never reuse a Protobuf field number.
- Add new fields as optional with defaults.
- Version breaking message shapes (`*.v2`).
- Keep JSON fixtures in `schemas/fixtures/` for cross-language tests.
- Record minimum supported consumer version when dispatching new command types.

---

## Fixtures

Example layout:

```text
schemas/fixtures/command_resource_assign.v1.json
schemas/fixtures/event_resource_started.v1.json
```

Fixtures are validated in CI against Protobuf JSON mapping (or the service's schema tooling).

---

## Related documents

- [Conventions overview](README.md)
- [REST API conventions](api.md)
- [Architecture Decision Records](../adr/README.md)
