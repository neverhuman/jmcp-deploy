#!/usr/bin/env bash
set -Eeuo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

cd "$ROOT_DIR"
mkdir -p target/jankurai

log "release-readiness: validating release evidence surface"
python3 - <<'PY'
import json
from pathlib import Path

required_files = [
    "CHANGELOG.md",
    "docs/release.md",
    "docs/testing.md",
    "docs/operations.md",
    "agent/cost-budget.toml",
]
missing = [path for path in required_files if not Path(path).exists()]
release = Path("docs/release.md").read_text()
testing = Path("docs/testing.md").read_text()
required_terms = [
    "just fast",
    "just security",
    "just conformance",
    "just contract-drift",
    "just ux-qa",
    "just cost-budget",
    "target/jankurai",
    "rollback",
]
missing_terms = [term for term in required_terms if term not in release and term not in testing]
receipt = {
    "ok": not missing and not missing_terms,
    "required_files": required_files,
    "missing_files": missing,
    "missing_terms": missing_terms,
    "artifact_paths": [
        "target/jankurai/release-readiness.json",
        "target/jankurai/cost-budget.json",
        "target/jankurai/security/evidence.json",
    ],
}
Path("target/jankurai/release-readiness.json").write_text(json.dumps(receipt, indent=2) + "\n")
if not receipt["ok"]:
    raise SystemExit(f"release readiness missing evidence: files={missing} terms={missing_terms}")
PY

log "release-readiness: complete"
