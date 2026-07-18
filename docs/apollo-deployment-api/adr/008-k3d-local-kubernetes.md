# ADR 008: k3d for local Kubernetes

**Status:** Proposed  
**Date:** 2026-07-18

## Context

The MVP runtime adapter targets Kubernetes. Developers need a local cluster for Phase 4+ without adding K8s to the default `make dev` stack.

## Decision

Use **[k3d](https://k3d.io/)** for local Kubernetes:

- Cluster name: `apollo-deploy`
- Config: `infrastructure/local/k3d/k3d.yaml`
- Commands: `make k3d-up`, `make k3d-down`
- **Not** started by default with `make dev` — opt-in when working on runtime/reconcile.

Traefik is disabled in k3s; ingress controller choice is explicit in Phase 4 manifests.

Production and staging use managed Kubernetes (EKS, GKE, etc.) — same `RuntimeProvider` interface.

## Consequences

### Positive

- Lightweight single-node cluster on Docker.
- Same kubectl/API surface as production.
- Optional — Phase 0–2 work does not require k3d.

### Negative

- Requires Docker and k3d installed.
- Not identical to production node pools (acceptable for dev).

## Follow-ups

- Phase 4: `KubernetesRuntimeProvider` integration tests against k3d.
