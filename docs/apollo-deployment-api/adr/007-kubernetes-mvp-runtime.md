# ADR 007: Kubernetes as MVP runtime

**Status:** Proposed  
**Date:** 2026-07-18

## Context

The MVP must run OCI images with health checks, rolling updates, ingress, and isolation without exposing cluster credentials to customers.

## Decision

The MVP runtime adapter is **Kubernetes + containerd**:

- Kotlin `RuntimeProvider` generates Deployments, Services, ConfigMaps, Secrets, NetworkPolicies, and probes.
- A runtime reconciler compares desired Apollo state with observed cluster state.
- Customers never receive kubeconfig or API access.

Future adapters (`ContainerdRuntimeProvider`, `FirecrackerRuntimeProvider`) may exist behind the same interface but are out of MVP scope.

Local Kubernetes uses **k3d** (ADR 008) — optional, not started by `make dev`.

TLS for platform routes is **edge-managed** (ADR 012); in-cluster cert-manager is optional for MVP.

## Consequences

### Positive

- Mature rolling deployment and ingress ecosystem.
- Runtime abstraction keeps domain logic portable.

### Negative

- Cluster operations add operational burden.
- Local full-stack dev is heavier once K8s work begins.

## Follow-ups

- Phase 4: `KubernetesRuntimeProvider` and first regional cluster.
- Phase 5: Ingress integration; custom domains via edge TLS (ADR 012).
