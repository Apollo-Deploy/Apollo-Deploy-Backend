# Apollo API Documentation

**TL;DR:** Architecture decisions and API conventions for Apollo services, organized by project.

## Overview

This folder holds cross-project documentation that defines how Apollo APIs are designed,
built, and operated. The goal is for these documents to serve as the source of truth for
API-related guidance across the fleet and the way teams discuss and reach consensus on
implementation choices.

The program is named and styled after [Google's API Improvement Proposals (AIPs)](https://aip.dev/)
and Python's enhancement proposals (PEPs), which have worked well as durable design records.

### Organization

| Layer | Location | Purpose |
|-------|----------|---------|
| **Fleet-wide guides** | [`adr/`](adr/README.md), [`conventions/`](conventions/README.md) | How to write ADRs and API/event conventions |
| **Project docs** | `docs/<project-name>/` | Accepted ADRs and service-specific extensions |
| **Shared references** | Top-level files (for example [M2M auth](m2m-authentication.md)) | Cross-cutting fleet guidance |

Each project may define:

- **ADRs** — Architecture Decision Records under `docs/<project-name>/adr/`
- **Conventions** — Extensions under `docs/<project-name>/conventions/` when the fleet defaults are not enough

## Getting started

### New to Apollo API docs?

1. Read [Architecture Decision Records](adr/README.md) for how decisions are recorded.
2. Read [REST API conventions](conventions/api.md) and [event conventions](conventions/events.md) before changing public surfaces or messaging contracts.
3. Check the project's `docs/<project-name>/` folder for accepted ADRs and any service-specific extensions.

### Adding documentation for a new project?

1. Create `docs/<project-name>/adr/` when the service has architecture decisions to record.
2. Create `docs/<project-name>/conventions/` only when the service needs documented extensions beyond the fleet guides.
3. Add rows to the project tables in [adr/README.md](adr/README.md) and [conventions/README.md](conventions/README.md).
4. Link from the project's `README.md` and `AGENTS.md`.

### Proposing a new ADR?

Copy [adr/TEMPLATE.md](adr/TEMPLATE.md), follow [adr/README.md](adr/README.md), increment the numeric prefix for that project, and start in **Proposed** status until reviewed.

## Projects

| Project | ADRs | Conventions |
|---------|------|-------------|
| [apollo-deployment-api](apollo-deployment-api/adr/README.md) | [12 proposed](apollo-deployment-api/adr/README.md) | [Extensions](apollo-deployment-api/conventions/api.md) |

## Cross-project references

- [Machine-to-Machine (M2M) authentication](m2m-authentication.md) — OAuth 2.1 `client_credentials` for internal APIs

## License

Except as otherwise noted, the content of this repository is licensed under the
[Creative Commons Attribution 4.0 License][1], and code samples are licensed
under the [Apache 2.0 License][2].

[1]: https://creativecommons.org/licenses/by/4.0/
[2]: https://www.apache.org/licenses/LICENSE-2.0
