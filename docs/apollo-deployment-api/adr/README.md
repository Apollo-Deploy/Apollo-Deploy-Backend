# Architecture Decision Records — apollo-deployment-api

Architecture decisions for the Deployment API. Read these before changing control-plane / systems-plane boundaries, messaging, or runtime adapters.

**Format and process:** [Fleet ADR guide](../../adr/README.md)

> **All ADRs are currently Proposed** — pending team review and approval before implementation proceeds. Change status to **Accepted** in the PR that ratifies each decision.

| ADR | Title | Status |
|-----|-------|--------|
| [001](001-control-and-systems-plane-split.md) | Control plane vs systems plane split | Proposed |
| [002](002-modular-monolith-control-plane.md) | Modular monolith control plane | Proposed |
| [003](003-dual-postgresql-platform-vs-deployment.md) | Dual PostgreSQL — platform vs deployment | Proposed |
| [004](004-protobuf-inter-service-contracts.md) | Protobuf inter-service contracts | Proposed |
| [005](005-nats-jetstream-event-bus.md) | NATS JetStream event bus | Proposed |
| [006](006-temporal-durable-workflows.md) | Temporal for durable workflows | Proposed |
| [007](007-kubernetes-mvp-runtime.md) | Kubernetes as MVP runtime | Proposed |
| [008](008-k3d-local-kubernetes.md) | k3d for local Kubernetes | Proposed |
| [009](009-cloudflare-r2-object-storage.md) | Cloudflare R2 for object storage | Proposed |
| [010](010-cloud-oci-registry.md) | Cloud OCI registry | Proposed |
| [011](011-opentelemetry-otlp.md) | OpenTelemetry (OTLP) observability | Proposed |
| [012](012-edge-managed-tls.md) | Edge-managed TLS | Proposed |

New ADRs: copy [TEMPLATE.md](../../adr/TEMPLATE.md), increment the prefix, add a row here, and open a PR for review.
