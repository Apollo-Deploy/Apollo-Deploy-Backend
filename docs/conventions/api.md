# REST API Conventions

Apollo public APIs follow [Google API Improvement Proposals (AIPs)](https://aip.dev/) — resource-oriented design, standard methods, and consistent error and pagination shapes — adapted for JSON REST and multi-tenant services.

Primary references:

| Topic | AIP |
|-------|-----|
| Resource-oriented design | [AIP-121](https://google.aip.dev/121) |
| Resource names | [AIP-122](https://google.aip.dev/122) |
| HTTP mapping | [AIP-127](https://google.aip.dev/127) |
| Get / List / Create / Update / Delete | [AIP-131](https://google.aip.dev/131) – [AIP-135](https://google.aip.dev/135) |
| Custom methods | [AIP-136](https://google.aip.dev/136) |
| Long-running operations | [AIP-151](https://google.aip.dev/151) |
| Pagination | [AIP-158](https://google.aip.dev/158) |
| Request idempotency | [AIP-155](https://google.aip.dev/155) |
| Errors | [AIP-193](https://google.aip.dev/193) |

Internal M2M routes (`/internal/v1/...`) follow the same conventions unless noted otherwise.

---

## Design principles

From [AIP-121](https://google.aip.dev/121):

1. **Resources are nouns** arranged in a hierarchy (for example `organizations → projects → resources`).
2. **Standard methods** (`Get`, `List`, `Create`, `Update`, `Delete`) cover most CRUD. Prefer them over bespoke endpoints.
3. **Custom methods** (`:activate`, `:archive`) express imperative operations that do not map cleanly to CRUD.
4. **Stateless protocol** — each request is independently authorized; the server holds durable state.
5. **Strong consistency on the management plane** — after a successful `Create`/`Update`/`Delete`, a subsequent `Get` reflects steady-state (or `NOT_FOUND` after delete).

The API surface is **not** a 1:1 mirror of database tables.

---

## Base URL and versioning

```text
https://api.<service>.apollodeploy.com/v1/{resource_name...}
```

- Major version is a URI prefix (`/v1`). Breaking changes ship under `/v2`.
- Resource names in paths omit the leading slash and version.
- Every response includes a correlating **`X-Request-Id`** header (and echoes it in errors).

---

## Resource names

Every resource exposes a canonical string field **`name`**: the relative resource name ([AIP-122](https://google.aip.dev/122)).

```text
organizations/{organization}
organizations/{organization}/<collection>/{resource}
organizations/{organization}/<collection>/{resource}/<nested-collection>/{nested-resource}
```

Rules:

- Collection segments are **plural**, lower camelCase when compound.
- ID segments are URL-safe (lowercase letters, digits, hyphens; max 63 chars for user-specified IDs per [AIP-133](https://google.aip.dev/133)).
- Services may expose a short opaque **`uid`** (output only) for logs and CLI display. **`name` is authoritative** for API calls.
- Cross-resource references use the full resource **`name` string**, not embedded resource objects ([AIP-122](https://google.aip.dev/122)).
- Cyclic references between mutable fields are forbidden.

### Example resource

```json
{
  "name": "organizations/acme-corp/projects/web/resources/example-item",
  "uid": "res_01j5k2m3n4p5",
  "state": "ACTIVE",
  "createTime": "2026-07-17T12:00:00Z",
  "updateTime": "2026-07-17T12:00:05Z"
}
```

Timestamps use RFC 3339 (`createTime`, `updateTime`, `deleteTime`) — not `created_at`.

---

## Standard methods

HTTP mapping follows [AIP-127](https://google.aip.dev/127). JSON field names use **lowerCamelCase** on the wire.

| Method | HTTP | Path pattern | Returns |
|--------|------|--------------|---------|
| **Get** | `GET` | `/v1/{name=organizations/*/.../resources/*}` | The resource |
| **List** | `GET` | `/v1/{parent=organizations/*/...}/resources` | `{ resources[], nextPageToken }` |
| **Create** | `POST` | `/v1/{parent=…}/resources` body = resource | The created resource |
| **Update** | `PATCH` | `/v1/{name=…}` body = resource (field mask optional) | The updated resource |
| **Delete** | `DELETE` | `/v1/{name=…}` | Empty body; `204 No Content` or the deleted resource |

Conventions:

- **Get** — URI contains a single `{name}` variable; no request body ([AIP-131](https://google.aip.dev/131)).
- **List** — required `parent`; pagination query params (below). Response collection field name matches the plural resource and is **field 1** in the JSON object ([AIP-158](https://google.aip.dev/158)).
- **Create** — `{resource}Id` may be supplied as a query parameter for user-specified IDs ([AIP-133](https://google.aip.dev/133)). Duplicate name → `ALREADY_EXISTS`. Server-generated IDs are allowed when `{resource}Id` is omitted.
- **Update** — use `PATCH` with partial resource body; prefer field masks for large resources ([AIP-134](https://google.aip.dev/134)).
- **Delete** — soft-delete resources expose `deleteTime`; hard-deleted resources return `NOT_FOUND` on subsequent `Get`.

Every mutable resource supports **Get**. Collection-backed resources support **List**.

---

## Custom methods

Operations that are not CRUD use **`POST`** with a **`:` verb** suffix ([AIP-136](https://google.aip.dev/136)):

| Operation | HTTP | Example |
|-----------|------|---------|
| Activate | `POST` | `/v1/{name=…/resources/*}:activate` |
| Archive | `POST` | `/v1/{name=…/resources/*}:archive` |

Rules:

- Verb is **VerbNoun** in RPC terms (`ActivateResource`) → URI `:activate`, `:archive` (camelCase after `:`).
- Do not use standard method verbs (`get`, `list`, `create`, …) in custom names.
- Side-effecting methods use **`POST`** with `body: "*"` (full request message as JSON body).
- Long-running work returns a **long-running operation** (see below), not the final resource immediately.

---

## Long-running operations

Async work returns an **`Operation`** object ([AIP-151](https://google.aip.dev/151)):

```json
{
  "name": "operations/op_01j5k2m3n4p5",
  "done": false,
  "metadata": {
    "@type": "type.apollodeploy.com/ExampleMetadata",
    "resource": "organizations/acme/.../resources/example-item"
  }
}
```

When `done` is `true`, `response` contains the final resource (or `error` contains failure details). Clients poll `GET /v1/{name=operations/*}` or subscribe to events (see [events.md](events.md)).

---

## Pagination

List methods use token pagination ([AIP-158](https://google.aip.dev/158)) — **required from day one** on every collection.

**Request query parameters:**

| Parameter | Type | Description |
|-----------|------|-------------|
| `pageSize` | int | Max items to return. Default **50**, max **1000** (values above max are coerced). |
| `pageToken` | string | Opaque token from a previous response. |

**Response:**

```json
{
  "resources": [ "..." ],
  "nextPageToken": "eyJ..."
}
```

- Empty or omitted `nextPageToken` means end of collection.
- `pageToken` must be **opaque** (not client-parseable).
- Changing `pageSize` on a subsequent page is allowed; other list filters must match the call that produced the token or return `INVALID_ARGUMENT`.
- Negative `pageSize` → `INVALID_ARGUMENT`.

Optional: `totalSize` (estimate) when cheap to compute.

---

## Request identification and idempotency

Create and other non-safe retries accept an optional **`requestId`** ([AIP-155](https://google.aip.dev/155)):

- JSON body field on `Create` and custom mutating methods.
- HTTP header alias: **`X-Request-Id`** (UUID v4 recommended).
- When provided, duplicate requests within the retention window return the **same success response** without re-executing side effects.
- Conflicting payload with the same `requestId` → `ALREADY_EXISTS` or `INVALID_ARGUMENT` with stable `ErrorInfo.reason`.

Retention window: **24 hours** (documented; may extend in production).

---

## Errors

Errors follow the [AIP-193 HTTP/JSON shape](https://google.aip.dev/193):

```json
{
  "error": {
    "code": 404,
    "message": "Resource organizations/acme/.../resources/x was not found.",
    "status": "NOT_FOUND",
    "details": [
      {
        "@type": "type.apollodeploy.com/ErrorInfo",
        "reason": "RESOURCE_NOT_FOUND",
        "domain": "platform.apollodeploy.com",
        "metadata": {
          "resourceName": "organizations/acme/.../resources/x"
        }
      }
    ]
  }
}
```

| Field | Purpose |
|-------|---------|
| `code` | HTTP status code (numeric) |
| `status` | Canonical gRPC-style code name (`NOT_FOUND`, `INVALID_ARGUMENT`, …) |
| `message` | Developer-facing English description; stable when `ErrorInfo` is absent |
| `details` | Structured payloads; **`ErrorInfo` is required** |

`ErrorInfo.reason` is **UPPER_SNAKE_CASE**, max 63 chars ([AIP-193](https://google.aip.dev/193)). Pair `(reason, domain)` uniquely identifies an error class for client logic.

Common mappings:

| Situation | `status` | HTTP |
|-----------|----------|------|
| Bad input | `INVALID_ARGUMENT` | 400 |
| Missing auth | `UNAUTHENTICATED` | 401 |
| Missing permission | `PERMISSION_DENIED` | 403 |
| Resource missing (caller authorized) | `NOT_FOUND` | 404 |
| Duplicate / idempotency conflict | `ALREADY_EXISTS` | 409 |
| State precondition failed | `FAILED_PRECONDITION` | 412 |
| Rate limited | `RESOURCE_EXHAUSTED` | 429 |
| Internal failure | `INTERNAL` | 500 |
| Dependency down | `UNAVAILABLE` | 503 |

**Authorization errors** ([AIP-193](https://google.aip.dev/193)): if the caller lacks permission to know a resource exists, return **`PERMISSION_DENIED`** (not `NOT_FOUND`). Check permission before existence.

Validation failures include a `BadRequest` detail with field violations when applicable.

Every error includes **`X-Request-Id`**.

---

## Authentication and authorization

- **User requests:** `Authorization: Bearer` (Apollo Platform OAuth).
- **Service requests:** OAuth 2.1 client credentials (M2M). See [M2M authentication](../m2m-authentication.md).
- Every method validates **organization ownership** via the resource hierarchy (`organizations/{organization}/…`).

---

## OpenAPI

- Public specs live in each service's `schemas/openapi/` (or equivalent).
- Specs are generated from route definitions where possible.
- Scalar docs served at `/docs` in development.
- OpenAPI operation IDs match RPC names (`GetResource`, `CreateResource`, `ActivateResource`).

---

## Related documents

- [Conventions overview](README.md)
- [Event conventions](events.md)
- [Architecture Decision Records](../adr/README.md)
- [Google AIPs repository](https://github.com/aip-dev/google.aip.dev)
