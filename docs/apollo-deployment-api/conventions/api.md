# Deployment API — REST extensions

Extends the fleet-wide [REST API conventions](../../conventions/api.md) for the deployment domain.

---

## Base URL

| Environment | URL |
|-------------|-----|
| Production | `https://api.deploy.apollodeploy.com/v1/...` |
| Local dev | `http://api.deploy.localhost/v1/...` (when wired in nginx) |

Deployed applications use platform hostnames on **`apollodeploy.run`** (see [routing doc](../../../apollo-deployment-api/docs/07-routing-domains-and-tls.md)).

Error `ErrorInfo.domain` for this API: **`deploy.apollodeploy.com`**.

---

## Resource hierarchy (MVP)

```text
organizations/{organization}
  └── projects/{project}
        └── applications/{application}
              ├── services/{service}          # MVP: one per application
              ├── builds/{build}
              ├── releases/{release}          # immutable
              ├── deployments/{deployment}
              ├── secrets/{secret}
              └── domains/{domain}
```

### Resource name examples

```text
organizations/{organization}/projects/{project}/applications/{application}/deployments/{deployment}
organizations/{organization}/projects/{project}/applications/{application}/builds/{build}
organizations/{organization}/projects/{project}/applications/{application}/releases/{release}
```

### Example resource

```json
{
  "name": "organizations/acme-corp/projects/web/applications/example-api/deployments/deploy-20260717-a",
  "uid": "dep_01j5k2m3n4p5",
  "state": "DEPLOYING",
  "createTime": "2026-07-17T12:00:00Z",
  "updateTime": "2026-07-17T12:00:05Z"
}
```

---

## Custom methods

| Operation | HTTP | Example |
|-----------|------|---------|
| Deploy release | `POST` | `/v1/{name=…/applications/*}:deploy` |
| Rollback | `POST` | `/v1/{name=…/applications/*}:rollback` |
| Scale | `POST` | `/v1/{name=…/services/*}:scale` |
| Cancel build | `POST` | `/v1/{name=…/builds/*}:cancel` |

Long-running build and deploy operations return an `Operation` (see fleet [REST conventions](../../conventions/api.md#long-running-operations)).

---

## Domain-specific rules

These extend AIPs for the deployment domain (see [domain model](../../../apollo-deployment-api/docs/02-domain-model.md)):

| Rule | Detail |
|------|--------|
| **Secret values** | Write-only after creation; `Get`/`List` return metadata only. |
| **Release immutability** | Releases are create-only; changes produce a new release resource. |
| **Deployment history** | Deployments are append-only state machines; failed deployments are never mutated to success. |
| **Rate limiting** | `429 RESOURCE_EXHAUSTED` with `Retry-After`; per-organization and per-API-key limits. |

---

## OpenAPI

- Public specs live in `schemas/openapi/`.
- Specs are generated from Ktor route definitions (Phase 2+).
- OpenAPI operation IDs match RPC names (`GetDeployment`, `CreateBuild`, `DeployApplication`).

---

## Related documents

- [Fleet REST API conventions](../../conventions/api.md)
- [Deployment event extensions](events.md)
- [Deployment state machine](../../../apollo-deployment-api/docs/deployment-state-machine.md)
- [Domain model](../../../apollo-deployment-api/docs/02-domain-model.md)
- [Kotlin control plane](../../../apollo-deployment-api/docs/03-kotlin-control-plane.md)
