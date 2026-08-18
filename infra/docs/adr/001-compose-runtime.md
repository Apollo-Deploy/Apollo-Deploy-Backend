# ADR 001: Compose owns the Apollo runtime

Status: accepted for implementation

Date: 2026-08-18

## Context

Apollo runs three APIs and their PostgreSQL, PgBouncer, Redis, reverse-proxy,
and backup dependencies on one developer machine or one production VPS. Signal
also needs durable AWS infrastructure and production DNS is managed in
Cloudflare.

The existing system gives Terraform both external-infrastructure and host-local
container ownership. Shell code then compensates for the resulting cross-tool
lifecycle with state annotations, target fingerprints, remote identity and
release checkpoints, Docker inventory comparisons, a custom lease, and
procedural pre/post-apply stages.

## Options

### A. Terraform manages everything

Advantages:

- One graph and state snapshot describes cloud and Docker resources.
- Existing state addresses and `prevent_destroy` declarations remain in place.

Disadvantages:

- Application secrets and complete container environment arrays persist in
  state and plan artifacts.
- Every application release couples the AWS, DNS, SSH and Docker lifecycles.
- Host-local convergence needs procedural shell around Terraform.
- Local development needs Terraform and state for ordinary container startup.
- Recovery from either state/host drift requires custom dual-identity logic.

This option does not meet the simplification objective.

### B. Terraform plus Docker Compose

Terraform owns AWS, Cloudflare and its S3 backend. Compose owns the canonical
host topology, volumes, networks, health checks and process restart policy.
A small CLI renders protected runtime data, invokes explicit migrations and
connects to the VPS with deterministic SSH.

Advantages:

- Each tool owns the lifecycle it models natively.
- Local and VPS use the same topology; local adds one source-mount override and
  production injects immutable image digests through its staged env file.
- Production releases become a short pull/migrate/up/health transaction.
- Application secrets leave Terraform state.
- Compose can converge missing containers after daemon restart or operator
  deletion without a parallel Docker state file.

Disadvantages:

- The one-time Docker state handoff must be reviewed and applied safely.
- Compose does not provide a distributed deployment transaction or automatic
  rollback; the CLI must stage configuration, use `flock`, and preserve the
  prior current release until health succeeds.
- External persistent volumes must be created and checked explicitly.

### C. Repository-specific alternatives

Direct `docker run` would remove Compose but move topology and lifecycle back
into Bash. A systemd unit per container duplicates Compose's dependency and
configuration model. Kubernetes, Nomad, Ansible and a custom deployment daemon
add components without a current multi-host requirement.

The smallest repository-specific refinement is therefore Option B with:

- external named volumes and network created only during setup;
- Nginx and Certbot retained under Compose for ingress parity, with their
  programs moved out of Terraform HCL;
- the existing Cosign/SLSA verifier retained until the three publisher
  workflows expose one native signed release artifact that deployment can
  verify directly;
- `/etc/machine-id` plus strict SSH host-key checking replacing the remote
  deployment identity document;
- explicit adoption/recovery commands kept outside normal deployment.

## Decision

Select Option B with the repository-specific refinements above.

The intended ownership boundary is:

```text
GitHub release catalog + attestations
                 |
              Apollo CLI
            /            \
 local Compose          VPS Compose -- flock
                            |
                  Platform / Signal / Billing
                  PostgreSQL / Redis / Nginx

Terraform -- S3 lockfile
    |-- Signal AWS
    `-- Cloudflare DNS
```

## Security implications

- External Compose volumes are never removed by `docker compose down`, even
  with its volume flag. Normal commands still prohibit that flag entirely.
- Compose receives only digest-qualified production application images.
- Per-service runtime env files limit secret sharing and are mode 0600.
- Strict SSH options and the native machine ID bind the deployment target.
- Terraform's provider `allowed_account_ids` and S3 lockfile replace repeated
  account and concurrency machinery.
- Nginx and Certbot keep certificate behavior and persistent external volumes;
  no container receives the Docker socket.

## Tradeoffs

The implementation optimizes for one VPS. It deliberately does not provide
multi-host scheduling, zero-downtime rolling replicas, or a general deployment
platform. Expand migrations permit safe retry or rollback to the prior release,
but a crash during Compose convergence can temporarily leave mixed service
versions. The next deploy or rollback command is the recovery mechanism.

## TLS decision

Replacing the current TLS path with stock Caddy would remove roughly 800-1,000
lines of certificate bootstrap, renewal, reload and health machinery plus the
Certbot container. Current Caddy supports automatic HTTPS, reverse proxying,
WebSockets, request-body limits, response headers and static trusted proxy
ranges. Stock Caddy does not, however, preserve the current Nginx `limit_req`
per-IP controls without a plugin or an enforced Cloudflare rate-limit policy.
Changing both ingress and its abuse-control boundary during the Docker
ownership migration would weaken the closing evidence. Nginx/Certbot therefore
move to Compose in this ADR; Caddy remains a separate parity-tested migration.

## Migration implications

The production Terraform root must first replace its Docker module call with a
`removed` block using `destroy = false`. A reviewed saved plan must show state
handoff only and no remote Docker deletion. Compose then adopts the existing
fixed network and persistent volume names. Stateless containers are recreated
under Compose; volumes are never recreated during normal deploy.

Local Terraform becomes a one-time adoption concern and is not part of the new
normal workflow. Existing local containers can be replaced after their named
volumes and configuration are verified.

## Revisit triggers

Reconsider this decision only if Apollo requires multiple production hosts,
independent horizontal scaling, or availability objectives that a single VPS
cannot satisfy. Those are topology changes, not reasons to retain a custom
single-host control plane today.
