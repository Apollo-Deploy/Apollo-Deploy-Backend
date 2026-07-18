# Architecture Decision Records

**TL;DR:** ADRs capture significant technical decisions so teams can discuss, review, and revisit them with shared context.

## Overview

An ADR is a short design document that records an important architecture choice: what was decided, why, and what trade-offs follow. ADRs are the source of truth for decisions that constrain implementation across Apollo services.

The format is inspired by [Google AIPs](https://aip.dev/) and Python PEPs — durable, numbered, and easy to review in pull requests.

## When to write an ADR

Write an ADR when a decision:

- Is hard to reverse or expensive to change later
- Affects more than one module, service, or team
- Introduces a new dependency, protocol, or runtime boundary
- Needs explicit consensus before implementation proceeds

Skip ADRs for routine implementation details, bug fixes, or choices already covered by an existing ADR.

## File layout

Each service stores its ADRs under:

```text
docs/<project-name>/adr/
  README.md          # index table for that project
  001-short-title.md
  002-another-title.md
```

Fleet-wide ADR guidance lives here in `docs/adr/`. Project-specific decisions live under `docs/<project-name>/adr/`.

## Format

Every ADR includes:

| Section | Purpose |
|---------|---------|
| **Status** | `Proposed`, `Accepted`, `Deprecated`, or `Superseded by ADR NNN` |
| **Date** | When the decision was recorded |
| **Context** | Forces, constraints, and problem statement |
| **Decision** | What was chosen — be specific |
| **Consequences** | Trade-offs, risks, and follow-up work |

Use [TEMPLATE.md](TEMPLATE.md) when authoring a new ADR.

## Numbering and status

- Increment the three-digit prefix per project (`001`, `002`, …).
- New ADRs start as **Proposed** until reviewed and merged.
- Do not renumber accepted ADRs. Supersede with a new ADR instead.
- Update the project `adr/README.md` index when adding or changing status.

## Review process

1. Copy [TEMPLATE.md](TEMPLATE.md) into `docs/<project-name>/adr/`.
2. Fill in Context, Decision, and Consequences.
3. Add a row to the project's `adr/README.md` index.
4. Open a pull request and tag reviewers who own the affected boundary.
5. Merge with **Accepted** status once consensus is reached.

## Projects

| Project | Index |
|---------|-------|
| [apollo-deployment-api](../apollo-deployment-api/adr/README.md) | [12 proposed](apollo-deployment-api/adr/README.md) |

## Related documents

- [Apollo API documentation](../README.md)
- [REST API conventions](../conventions/api.md)
- [Event conventions](../conventions/events.md)
