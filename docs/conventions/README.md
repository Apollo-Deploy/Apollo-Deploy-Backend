# API Conventions

**TL;DR:** Fleet-wide rules for REST APIs and async messaging across Apollo services.

## Overview

These documents define how Apollo APIs are designed and operated. They apply to every public and internal HTTP surface unless a service documents an explicit, reviewed exception.

Conventions are aligned with [Google API Improvement Proposals (AIPs)](https://aip.dev/) where applicable, adapted for Apollo's JSON REST APIs and event-driven backends.

## Documents

| Document | Scope |
|----------|-------|
| [REST API conventions](api.md) | Resource names, standard methods, errors, pagination, auth |
| [Event and command conventions](events.md) | Envelopes, naming, delivery semantics, compatibility |

## Project-specific extensions

Services may add domain-specific rules under `docs/<project-name>/conventions/`. Extensions must:

- Link back to the fleet-wide document they build on
- Document only what differs from or extends the fleet defaults
- Avoid duplicating general guidance

| Project | Extensions |
|---------|------------|
| [apollo-deployment-api](../apollo-deployment-api/conventions/api.md) | Deployment resource hierarchy, domain rules, NATS subjects |

## Adding conventions for a new project

1. Read the fleet-wide [REST](api.md) and [event](events.md) conventions.
2. Create `docs/<project-name>/conventions/` only if the service needs documented extensions.
3. Add a row to the table above and link from the project's `README.md` and `AGENTS.md`.

## Related documents

- [Architecture Decision Records](../adr/README.md)
- [Machine-to-Machine authentication](../m2m-authentication.md)
- [Apollo API documentation](../README.md)
