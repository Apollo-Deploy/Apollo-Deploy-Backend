# Pre-implementation adversarial review

Review mode: full-cycle, pre-implementation baseline

Review depth: focused, not converged

Independent passes: one Red Team, one Simplifier

This is the preserved pre-fix baseline. Post-implementation rounds and the
final convergence result are recorded separately.

## Adjudication log

| ID | Priority | Reviewer | Disposition | Decision evidence | Operative change | Closing verification |
| --- | --- | --- | --- | --- | --- | --- |
| RT-1 | High | Red Team | ACCEPTED | Production validates service artifacts but stages mutable root migration helpers from the worktree | VPS mutation requires a clean exact `origin/main` infrastructure revision; staged helper set is hashed and tested before database access | Dirty-helper test fails before SSH/database mutation |
| RT-2 | High | Red Team | ACCEPTED | Docker env arrays and sensitive outputs persist the complete secret set in Terraform state | Compose owns containers; protected host secret files replace Terraform application/database secrets | State handoff plan has no secret-bearing Docker objects; secret scan and state audit run after rotation |
| RT-3 | High | Red Team | ACCEPTED | PR workflow passes a private token to checkout-controlled commands | PR job receives no repository/package secret; authenticated provenance verification runs only on protected push | Workflow policy regression test |
| RT-4 | High | Red Team | ACCEPTED | Backup health validates only marker age and same-host storage is the default | Versioned backup script, explicit offsite policy, restore command, and isolated restore verification | Truncated dump fails; valid dump restores and passes schema/data assertions |
| RT-5 | Medium/High | Red Team | ACCEPTED | Greenfield identity is derived from operator input and is persisted before target proof | Strict host-key checking plus native `/etc/machine-id`, explicit target summary, and separate adopt/recover path | Wrong machine ID and changed host key fail before mutation; empty setup can be corrected |
| RT-6 | Medium | Red Team | REJECTED as stated; hardening accepted | The reviewed catalog entry merged to protected `main` is the approval artifact; auto-generating it from a build would prove production, not approval | Require the exact clean `origin/main` catalog and retain provenance verification; document a future signed release-aggregation workflow | A dirty or non-main catalog is rejected; an approved exact entry passes |
| RT-7 | Medium | Red Team | ACCEPTED | Sixteen safety tests were deleted and only narrow replacements remain | Replace coverage for migration, target, release, backup, Compose data safety, SSH and CI secret isolation | Infrastructure gate enumerates and runs each replacement scenario |
| RT-8 | Medium | Red Team | ACCEPTED | Production Dockerfile base images use mutable tags while custom provenance records only source/workflow | Digest-pin production base images; keep upgrades separate and rebuild/reverify releases | Dockerfile policy test plus production image builds |
| S-1 | High | Simplifier | ACCEPTED | Terraform owns all Docker lifecycle locally and remotely | Base/local/VPS Compose stack; declarative Terraform `removed` handoff with `destroy = false` | Saved plans show state removal only and no Docker deletion |
| S-2 | High | Simplifier | ACCEPTED | Runtime secrets are state-backed | Mode-0600 source and rendered per-service runtime env files | Permission, symlink and tracked-secret tests |
| S-3 | High | Simplifier | ACCEPTED | Several state/target/release identities duplicate native sources | Native account restriction, strict SSH, machine ID, external volumes and staged/current release config | Wrong-target and missing-volume tests |
| S-4 | Medium | Simplifier | ACCEPTED | Custom FIFO/watchdog lease wraps remote `flock` | One complete idempotent remote operation under `flock` | Concurrent deploy test |
| S-5 | Medium | Simplifier | ACCEPTED | Local Terraform and custom update/health loops duplicate Compose | Compose up/wait/logs and explicit migration command | Fresh/repeated setup and unhealthy-service tests |
| S-6 | Medium | Simplifier | ACCEPTED | HCL, Terraform console, globals and generated env arrays duplicate configuration | One non-secret config plus protected secret source; rendered runtime files are derived | Key-set comparison and Compose config validation |
| S-7 | Medium | Simplifier | ACCEPTED | Bootstrap, DNS adoption and TLS are coupled to normal release work | Separate setup/adopt/deploy/recover operations | Normal deploy test proves no Terraform/bootstrap/adoption call |
| S-8 | Medium | Simplifier | DEFERRED | JLink and Gradle Dockerfile simplification requires measured image/startup evidence and is not required for the infrastructure ownership change | Keep JLink behavior; only pin its base images in this change | Existing image builds and health smoke tests |
| S-9 | Medium | Simplifier | ACCEPTED | Stock Caddy covers most ingress behavior but does not preserve current per-IP rate limits without a plugin or Cloudflare-only policy | Retain Nginx/Certbot under Compose; migrate Caddy separately after parity tests | Compose ingress tests preserve host routing, limits, headers, body caps, WebSockets, TLS renewal and health |
| S-10 | Medium | Simplifier | ACCEPTED | CI recursively validates retired modules and authenticates every PR | Validate two external Terraform roots, Compose, thin shell and manifest schema on PR; provenance on trusted push | Workflow policy test |
| S-11 | High | Simplifier | ACCEPTED, externally blocked | Ignored local HOCON has credential-bearing values | New local Compose uses protected env; credential rotation/removal requires operator/cloud authority | Secret scan and live Signal credential test after rotation |
| S-12 | Low/Medium | Simplifier | ACCEPTED | `terraform_data` repeats provider account restriction | Keep provider `allowed_account_ids` and concise CLI STS preflight | Wrong-account plan test |
| S-13 | Low/Medium | Simplifier | ACCEPTED | Permanent moved blocks preserve retired Docker addresses forever | Declarative state handoff and documented cleanup after all state is upgraded | Post-handoff state list contains no Docker resources |
| S-14 | Medium | Simplifier | ACCEPTED | Backup program is embedded in Terraform HCL | Versioned shell program owned by Compose | ShellCheck, health, retention and restore tests |

## Pre-implementation counterexamples

| Property under attack | Failure sequence | Baseline result | Required invariant |
| --- | --- | --- | --- |
| Reviewed production mutation | Dirty root migration helper plus approved service release | Helper reaches production credentials | Every executed production artifact is the exact reviewed root/service revision |
| Secret containment | Read current or retained remote state | Complete runtime credentials are recoverable | Application/database secrets never enter Terraform state or plans |
| PR secret isolation | Internal PR edits invoked shell and reads `GHCR_TOKEN` | Token is available to checkout-controlled code | Untrusted PR code receives no private token |
| Backup recoverability | Truncate a recent dump | Timestamp health can remain green | Restore evidence, not age alone, proves recoverability |
| Wrong VPS | Choose another already-known SSH host | Self-derived identity can bind and mutate it | Host key and independent native machine ID both match reviewed config |
| Persistent data | Remove an established volume then rerun setup | Setup may recreate an empty volume | Established setup fails closed when any durable volume is missing |
| Concurrent deploy | Start two valid deploys | Custom protocol eventually serializes them | Kernel `flock` admits exactly one mutation transaction |
| Interrupted release | Disconnect during Compose convergence | Runtime may be mixed | Current release is promoted only after health; retry/rollback is idempotent |
