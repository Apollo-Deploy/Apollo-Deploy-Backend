# Apollo infrastructure baseline audit

Audit date: 2026-08-18

This document freezes the pre-replacement worktree baseline. The worktree was
already dirty when the audit began; no existing user changes were reset or
discarded.

## Current architecture

The current implementation uses Terraform as both an external-infrastructure
tool and a Docker deployment engine. `infra/setup.sh` sources 25 shell modules,
which coordinate Terraform saved plans, remote SSH programs, database
migrations, OAuth records, release verification, host bootstrap, TLS, backups,
and health checks.

The local root builds or mounts three applications, creates secrets in
Terraform state, creates Docker resources, and runs reconciliation through a
`terraform_data` local provisioner. The VPS root manages AWS and Cloudflare as
well as the complete remote Docker lifecycle through the Docker provider over
SSH.

## Responsibility map

| Owner | Current responsibility | Current source of truth |
| --- | --- | --- |
| Terraform | AWS, Cloudflare DNS, images, containers, networks, volumes, OAuth credentials, generated application secrets, reconciliation triggers | Local and S3 state plus `terraform.tfvars` |
| Bash | CLI, prompting, state checks, target identity, saved-plan transaction, SSH policy, Docker inventory, release transition, migrations, TLS bootstrap, backup waits | Shell globals, generated payloads, remote programs |
| Docker | Runtime process supervision, health checks, named volumes, network, image cache | Docker daemon metadata and labels |
| AWS | Signal IAM, SES, SNS, SQS, S3, KMS, alarms, remote Terraform state | AWS control planes |
| Cloudflare | Production DNS and optional proxying | Cloudflare zone records |
| CI/CD | Terraform/shell checks, release-catalog checks, signatures and provenance | GitHub workflow and artifacts |
| VPS filesystem | Backend metadata copy, host bootstrap state, deployment identity, release checkpoint | `/opt/apollo` and host configuration |
| Application code | HTTP/SMTP behavior, migrations, application health endpoints | Three service repositories |
| Operator configuration | Host, domain, cloud account, regions, credentials, release, integrations | CLI options, ambient environment, service `.env`, two `terraform.tfvars`, backend HCL |

## Duplicated identities and configuration

The same deployment identity is represented by backend annotations, Terraform
state lineage, a target SHA, SSH host details, Docker creation timestamps, a
remote JSON marker, and live Docker IDs. The current release is represented by
the approved catalog, the VPS tfvars manifest, Terraform state, Docker image
references and labels, and the remote last-complete checkpoint.

Application configuration is split among local and VPS tfvars, three service
`.env` files, Terraform-generated secrets, Docker environment arrays, CLI
options and ambient `APOLLO_*` variables. Production application and database
secrets are consequently persisted in Terraform plans and state even when
marked sensitive.

## Complexity metrics

Counts exclude blank lines and comment-only lines where shown as code LOC.

| Metric | Committed `HEAD` | Audited worktree |
| --- | ---: | ---: |
| Shell code LOC | 11,872 | 7,781 |
| Terraform code LOC | 6,960 | 6,974 |
| Python code LOC | 306 | 306 |
| Shell files | 32 | 50 |
| Terraform files | 101 | 102 |
| Terraform module directories | 21 | 21 |
| Shell functions | 322 | 261 |
| Uppercase shell assignments (approximate global-state proxy) | 233 | 145 |

The in-progress modularization reduced the entrypoint from 3,955 lines to 109
lines, but increased the shell file count and retained the same Terraform and
deployment architecture. It therefore did not meet the replacement brief.

Additional baseline counts:

- Persistent deployment identity/checkpoint systems: 4 (backend annotations,
  state fingerprint, remote deployment marker, last-complete release).
- Primary durable/configuration sources: 9.
- Normal VPS transaction stages before Terraform's own graph execution: 6.
- Shell safety tests deleted in the audited worktree: 16; replacement safety
  test groups present: 3.

## Security invariants that must survive replacement

1. A normal deploy cannot delete PostgreSQL, Redis, backup, or TLS data.
2. Production application images are digest-qualified and verified against the
   repository and governed build workflow before mutation.
3. Only the configured SSH host key and native VPS machine identity may receive
   a production deployment.
4. Terraform refuses an unexpected AWS account and uses encrypted, versioned,
   remotely locked state.
5. At most one production deploy and one migration per database run at a time.
6. Normal deployment runs expand migrations only; contract migrations remain
   deliberate.
7. Application secrets do not enter Terraform configuration, plans, or state.
8. A failed migration prevents application rollout; a failed health gate does
   not become a completed release.
9. Backups have an age signal and a separate restore-verification procedure.
10. SSH host-key changes, missing persistent data, missing secrets, invalid
    releases, and unknown configuration fail closed.

## Confirmed architectural findings

| Threat | Current protection | Weakness | Simpler protection | Residual risk |
| --- | --- | --- | --- | --- |
| Application secret disclosure | Sensitive Terraform values, encrypted state | Sensitive only masks output; Docker env and secrets are still stored in state and plans | Mode-0600 source files rendered into per-service runtime env files | Root and Docker administrators can still inspect runtime env |
| Persistent data loss | Terraform `prevent_destroy` plus creation-identity checks | Safety depends on Terraform remaining Docker's owner and on parallel identity metadata | Pre-created external Compose volumes; deploy never creates or removes them | A privileged host administrator can still delete volumes |
| Concurrent deploy | Custom remote lease protocol plus state locking | Bespoke lease lifecycle and SSH failure paths | VPS `flock` for runtime mutation; S3 lockfile for Terraform; CI concurrency | Operator must investigate a genuinely stale Terraform lock |
| Wrong VPS | Strict SSH plus custom marker | Several mutable identity copies must agree | Strict host-key checking plus `/etc/machine-id` captured at setup | Intentional host replacement requires an explicit adoption step |
| Mutable/unapproved image | Catalog, custom Cosign and SLSA verifier, state checkpoint | More than 500 lines combine verification with registry graph parsing | A smaller `cosign verify`/`verify-attestation` wrapper today; GitHub CLI verification after publishers emit GitHub attestations | Registry and transparency-log availability are required unless bundles are cached |
| Interrupted deploy | Last-complete checkpoint and mixed-release verifier | Normal deploy owns a custom release state machine | Stage release env, expand-migrate, Compose converge, health gate, atomic promotion; old current config remains rollback input | A crash during Compose can leave a temporary mixed set until retry |
| TLS renewal failure | Nginx, Certbot, renewal marker, reload supervisor and health scripts | Terraform embeds and couples the complete TLS lifecycle to application deployment | Move the proven Nginx/Certbot behavior into Compose and versioned scripts; evaluate Caddy separately | ACME and public DNS remain external dependencies |
| Backup is corrupt | Backup age marker and container health | Age proves creation, not restoration | Keep age health and add isolated restore verification | Restore drills still require operator scheduling and monitoring |

## Complexity hotspots and disposition

| Mechanism | Disposition | Replacement |
| --- | --- | --- |
| Terraform Docker provider and Docker modules | Replace | Docker Compose |
| Local Terraform root and generated local secrets | Delete | Local config plus mode-0600 secrets |
| `terraform_data` database reconciliation | Replace | Explicit CLI migration command |
| Backend lineage and target annotations | Delete | S3 backend coordinates, lockfile, native AWS account restriction |
| Docker creation identity checkpoint | Delete | External volumes and deploy-time existence checks |
| Custom SSH lease protocol | Delete | `flock` |
| Nginx/Certbot supervisor state | Simplify and move | Compose plus versioned renewal/reload programs; Caddy deferred pending rate-limit parity |
| Custom Cosign/SLSA parsing | Simplify | Native Cosign verification; migrate to GitHub CLI when publisher workflows emit GitHub attestations |
| Remote last-complete marker | Delete | Staged/current release env and live container state |
| Brownfield logic in normal setup/deploy | Move | Explicit `adopt`/recovery workflow |
| Migration phase manifest and advisory lock | Keep | Existing durable database invariant |
| Signal AWS and Cloudflare Terraform modules | Keep and flatten where useful | External-infrastructure-only root |
| S3 state bootstrap | Keep and simplify | Encrypted, versioned state with native lockfile |
