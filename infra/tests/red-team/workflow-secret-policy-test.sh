#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
workflow="$repo_root/.github/workflows/terraform.yaml"
python3 - "$workflow" <<'PY'
import pathlib
import sys

text = pathlib.Path(sys.argv[1]).read_text()
if "pull_request" not in text:
    raise SystemExit("FAIL: PR validation is missing")
if "if: github.event_name == 'push'" not in text:
    raise SystemExit("FAIL: authenticated verification is not push-gated")
quality, provenance = text.split("  release-provenance:", 1)
if "secrets." in quality:
    raise SystemExit("FAIL: pull-request quality job references a repository secret")
if "secrets.SUBMODULES_TOKEN" not in provenance:
    raise SystemExit("FAIL: trusted-push provenance job lost its registry credential")
print("Workflow secret-policy tests passed.")
PY
