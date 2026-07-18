# ADR 011: OpenTelemetry (OTLP) observability

**Status:** Proposed  
**Date:** 2026-07-18

## Context

Operations need traces and metrics across the Kotlin control plane, Temporal activities, and NATS handlers. Vendor-specific agents create lock-in.

## Decision

Standardize on **OpenTelemetry** with **OTLP** export:

```text
OTEL_EXPORTER_OTLP_ENDPOINT
OTEL_SERVICE_NAME=apollo-deploy-control-plane
```

- `kotlin/observability` owns SDK bootstrap and span helpers.
- Structured JSON logs include `trace_id` / `span_id` for correlation.
- Use OTel semantic conventions where applicable.
- Local dev: OTLP export is optional — stdout logging suffices until Phase 6; no collector in `make dev` by default.

Defer Grafana/Prometheus/Loki stacks until staging; the **export protocol** is fixed now.

## Consequences

### Positive

- Portable across Grafana Cloud, Honeycomb, Datadog OTLP ingest, etc.
- Same instrumentation when the monolith splits into services.

### Negative

- OTel SDK adds classpath weight (acceptable).

## Follow-ups

- Phase 1: Wire OTel in `apps/control-plane` startup.
- Phase 6: Dashboards and alerts on deployment workflow SLIs.
