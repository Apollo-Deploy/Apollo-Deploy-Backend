# Post-implementation adversarial review

Review mode: full-cycle, implementation review

Independent passes: three Red Team rounds and three Simplifier rounds

The pre-implementation findings are preserved in
[`review-baseline.md`](review-baseline.md). This file records the
post-implementation adjudication. Findings are implementation risks, not a
claim that the production VPS has already been cut over.

## Accepted findings and fixes

| Finding | Disposition | Closing evidence |
| --- | --- | --- |
| Fresh setup failed when the archived Nginx tree had no `certs` directory | Fixed | Staging deletes archived certificate files only when the directory exists |
| Certbot and backup startup health could not converge | Fixed | Initial-health intervals are bounded; certificate issuance and backup restore have explicit gates |
| Raw SSH argument construction allowed remote-shell injection | Fixed | Central single-quote encoding plus hostile-argument regression tests |
| Placeholder and malformed production secrets were accepted | Fixed | Production secret contract validates length, uniqueness, UUID/client formats and 32-byte Base64 keys |
| Ambient VPS variables could override approved image digests | Fixed | Every remote Compose call uses an allowlisted `env -i` environment |
| Registry credentials persisted in the operator Docker config | Fixed | Each deployment uses a temporary protected remote `DOCKER_CONFIG` and deletes it on exit |
| Old staged releases retained rotated secrets indefinitely | Fixed | Promotion retains only current and immediately previous release trees |
| Normal release depended on Terraform and AWS credentials | Fixed | Setup renders protected `vps.aws.env`; normal deploy consumes the cache without Terraform initialization |
| Release staging could race concurrent operators or reuse changed bytes | Fixed | Extraction and deployment use the same VPS lock file; a content identity is checked again after deployment lock acquisition |
| Nginx renewal ignored Certbot's symlinked live certificates | Fixed | The supervisor follows live certificate symlinks before hashing and reloads only after `nginx -t` |
| Container health did not prove public TLS routing | Fixed | Setup/deploy/adopt probe all three HTTPS routes and expected service identities, restoring the prior Compose release on failure |
| Public rollback replayed a hard-coded profile set | Fixed | Rollback receives the exact selected profile set, including optional offsite backup |
| TLS/public checks could interleave between concurrent operators | Fixed | Deployment, certificate issuance, public probes, rollback and promotion execute within one remote `flock` transaction |
| Rollback reused the candidate release's global Compose model | Fixed | Each staged release carries its own content-bound Compose model and rollback selects the previous model and env together |
| Adoption released its lock between legacy removal and Compose convergence | Fixed | Legacy container removal is an explicit deployment mode inside the same remote transaction as convergence and promotion |
| Health alone did not prove the intended release was running | Fixed | Deployment compares each live application container's digest-qualified image reference and revision label with the staged approved release |
| Ambient proxy variables could intercept public readiness probes | Fixed | Public HTTPS checks force direct connections while retaining normal certificate and hostname verification |
| Reusing the active release ID could overwrite its rollback tree | Fixed | Staging rejects changed content for the active release ID under the VPS lock |
| Signal health had no stable service identity field | Fixed | Production ingress adds an Apollo service identity header and all public probes assert it before promotion |

## Simplifier adjudication

- The redundant VPS Compose override was deleted; the base model is the whole
  production topology and its protected env file supplies immutable digests.
- Successful staging is bounded to current plus previous releases.
- The local Terraform transition root was removed after its state reached zero.
  The VPS `removed` block and external Docker network remain intentionally until
  production adoption has completed.
- Isolated backup restore remains in each backup-enabled deployment. The extra
  deployment time is accepted because recent-file age is not evidence that a
  dump is restorable.
- The custom provenance verifier remains until all three service publishers
  expose one native, signed release artifact/attestation that deployment can
  consume. Moving the same custom check to CI alone would weaken the current
  deploy-time trust boundary.
- Nginx/Certbot remains because the current per-IP rate-limit behavior is not
  preserved by the stock Caddy image. That migration needs its own parity test
  and policy decision.

## Convergence boundary

The final independent blocker review reports no remaining P0/P1 findings, and
`infra/scripts/check-infra.sh` passes. The repository and local-runtime
implementation are therefore converged.

Production convergence is separate: create the protected VPS files, review a
saved external-infrastructure plan, build and approve images containing the new
Dockerfile pins, perform the explicit adoption, and verify live HTTPS, backup,
restore and state evidence. No production apply or VPS mutation was performed
during this refactor.
