# ADR 012: Edge-managed TLS

**Status:** Proposed  
**Date:** 2026-07-18

## Context

Platform hostnames (`*.apollodeploy.run`) and many custom domains can terminate TLS at the edge (Cloudflare, cloud load balancer) instead of running cert-manager in every regional cluster for MVP.

Product and control-plane APIs live on **`apollodeploy.com`** (for example `api.deploy.apollodeploy.com`); deployed applications default to **`apollodeploy.run`**.

## Decision

**Platform domains (`*.apollodeploy.run`):**

- TLS terminates at the **edge** (Cloudflare or cloud load balancer).
- Regional ingress receives HTTP or re-encrypted origin traffic per security policy.
- No cert-manager requirement for MVP platform routes.

**Custom domains (Phase 5):**

- DNS verification + edge certificate provisioning (Cloudflare for SaaS or ACME at edge).
- cert-manager in-cluster is **optional** — use only when edge termination is impossible.

Kotlin domain service tracks certificate **status** from the edge provider API, not solely from in-cluster `Certificate` resources.

## Consequences

### Positive

- Simpler regional clusters (no cert-manager day-one).
- Fast certificate issuance at scale.
- Matches common PaaS edge routing patterns.

### Negative

- Edge provider dependency for cert lifecycle.
- Custom domain flows must integrate provider webhooks/APIs.

## Follow-ups

- Phase 5: Custom domain verification + edge cert status sync.
- Document origin TLS policy between edge and ingress.
