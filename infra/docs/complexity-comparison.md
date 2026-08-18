# Final complexity comparison

Counts use the same method as the baseline audit: code LOC excludes blank and
comment-only lines. The before column is the audited worktree immediately
before replacement, not the larger committed `HEAD` implementation.

| Metric | Before | After | Reduction |
| --- | ---: | ---: | ---: |
| Shell code LOC | 7,781 | 3,125 | 60% |
| Python code LOC | 306 | 306 | 0% |
| Terraform code LOC | 6,974 | 2,652 | 62% |
| Shell files | 50 | 33 | 34% |
| Terraform files | 102 | 57 | 44% |
| Terraform module directories | 21 | 9 | 57% |
| Shell functions | 261 | 103 | 61% |
| Uppercase shell assignments, approximate global-state proxy | 145 | 69 | 52% |
| Primary configuration sources | 9 | 4 | 56% |
| Persistent deployment identity/checkpoint systems | 4 | 1 | 75% |
| Approximate normal VPS release stages | 6 before Terraform graph execution | 6 total | External Terraform removed from normal releases |

The remaining Python is one data renderer for OAuth SQL; it is no longer
embedded in Terraform or Bash. The four primary sources are protected public
configuration, protected secrets, the approved immutable release catalog and
Terraform state for external resources. The sole deployment checkpoint is the
atomically promoted VPS `current-release`; SSH host keys, machine ID, image
labels, database migration history and Terraform state are native owner state,
not parallel custom checkpoint protocols.

The two largest retained shell programs are the existing migration runner and
Cosign/SLSA verifier. They protect real database and release provenance
boundaries. The verifier can shrink after all three publisher workflows emit
GitHub artifact attestations that can be verified with `gh attestation`; it is
not replaced before that upstream evidence exists.
