# Canonical jankurai CI lane template (Cluster 4.3)

Distilled from `~/jekko/ops/ci/jankurai.sh` — the per-repo adoption unit. Copy to a repo's
`ops/ci/jankurai.sh` and wire it into the repo's CI. It is what produces `.jankurai/repo-score.json`
(consumed by the fleet board) and enforces the score gate in CI.

## Skeleton
```bash
#!/usr/bin/env bash
set -euo pipefail
# 1) install the pinned auditor (signed) — see ~/jankurai/jankurai-installer.sh
#    JANKURAI_VERSION=1.6.10  bash jankurai-installer.sh
# 2) score the repo (writes .jankurai/repo-score.{json,md})
jankurai score . --mode standard
# 3) gate: fail CI if score < minimum_score or new hard findings/caps
jankurai diff-audit . --base-ref "origin/${GITHUB_BASE_REF:-main}"     # PRs
# (or, for main): a score-gate over .jankurai/repo-score.json (min 85, hard_findings==0)
# 4) copy-code (duplication, informational) + tool-adoption proof
jankurai copy-code . --json .jankurai/copy-code.json
```

## Notes
- Run on the FREE self-hosted runners (`runs-on: [self-hosted, linux, x64, <label>]`), never GitHub-hosted.
- `agent/tool-adoption.toml` `ci_command` strings are what the auditor looks for as adoption evidence —
  keep them invoked in CI so `tool_adoption.ci_evidence_count` rises (reduces the waste-report gap).
- The engine rule set (caps, HLT-* rules) is owned by `~/jankurai` (Codex). This template only wires the
  repo into it; do not redefine rules here.
