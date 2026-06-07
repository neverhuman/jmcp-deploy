set shell := ["bash", "-eu", "-o", "pipefail", "-c"]

default:
    @just --list

fast: fast-shell fast-json fast-actions

fast-shell:
    source ops/ci/common.sh; log "fast-shell: checking shell syntax"; while IFS= read -r script; do bash -n "$script"; done < <(find scripts ops jeryu-ctl tools -type f -name '*.sh' | sort)

fast-json:
    python3 -m json.tool agent/test-map.json >/dev/null

fast-actions:
    source ops/ci/common.sh; if has actionlint; then actionlint; else missing_tool actionlint "GitHub Actions linting"; fi

ci: fast test launch-dry-run health-offline

security: security-evidence

conformance:
    bash ops/ci/conformance.sh

jankurai-local:
    ./ops/ci/jankurai-local.sh

build:
    @echo "deploy repo has no product build"

test:
    python3 -m unittest discover -s tests -p '*_test.py'

launch-dry-run:
    ops/split/launch.sh --dry-run

health-offline:
    ops/split/health.sh --offline

split-smoke:
    ops/split/smoke.sh

ux-qa:
    bash ops/ci/ux-qa.sh

score: score-advisory

score-advisory:
    jankurai audit . --mode advisory --json .jankurai/repo-score.json --md .jankurai/repo-score.md --score-history .jankurai/score-history.jsonl --score-history-csv .jankurai/score-history.csv

proof-routing:
    jankurai proof . --changed-from "${JANKURAI_BASE_REF:-origin/main}" --out target/jankurai/proof-routing.json --md target/jankurai/proof-routing.md

proofbind:
    jankurai proofbind verify . --changed-from "${JANKURAI_BASE_REF:-origin/main}" --out target/jankurai/proofbind/surface-witness.json --obligations-out target/jankurai/proofbind/obligations.json --md target/jankurai/proofbind/proofbind.md

proofmark-rust:
    jankurai proofmark rust . --obligations target/jankurai/proofbind/obligations.json --out target/jankurai/proofmark/proofmark-receipt.json --proof-receipt target/jankurai/proofmark/proof-receipt.json --md target/jankurai/proofmark/proofmark.md

copy-code:
    jankurai copy-code . --json target/jankurai/copy-code.json --md target/jankurai/copy-code.md

security-evidence:
    jankurai security run --script ops/ci/security.sh --out target/jankurai/security/evidence.json

language-bad-behavior:
    bash ops/ci/language-bad-behavior.sh

rust-map:
    jankurai rust map .

rust-witness:
    jankurai rust witness build . --out target/jankurai/rust/witness-graph.json

rust-diagnose:
    jankurai rust diagnose .

contract-drift:
    bash ops/ci/contract-drift.sh

cost-budget:
    bash ops/ci/cost-budget.sh

release-readiness:
    bash ops/ci/release-readiness.sh

authz-matrix:
    jankurai audit . --mode advisory --json .jankurai/repo-score.json --md .jankurai/repo-score.md

input-boundary:
    jankurai audit . --mode advisory --json .jankurai/repo-score.json --md .jankurai/repo-score.md

agent-tool-supply:
    jankurai audit . --mode advisory --json .jankurai/repo-score.json --md .jankurai/repo-score.md

check: fast build test health-offline launch-dry-run security conformance contract-drift cost-budget release-readiness ux-qa score
