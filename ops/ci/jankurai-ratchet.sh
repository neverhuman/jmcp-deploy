#!/usr/bin/env bash
# Jankurai regression ratchet.
#
# Runs `jankurai audit` and FAILS (exit 1) if the result regresses versus the
# accepted baseline at agent/repo-score-baseline.json: a lower final score, a
# newly-applied cap, or more total findings. This makes it impossible to
# commit/push (via ops/git-hooks) — and, when wired into CI, to merge —
# anything that worsens the repository's jankurai conformance.
#
# The baseline is a compact summary ({score, raw_score, caps_applied,
# rule_counts}) shared with the CI audit lane. It only ratchets UP via
# `ops/ci/jankurai-ratchet.sh --accept`, run after a clean, improved audit.
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

BASELINE="${JANKURAI_BASELINE:-agent/repo-score-baseline.json}"
JANKURAI="${JANKURAI_BIN:-jankurai}"
MODE="${JANKURAI_RATCHET_MODE:-advisory}"
ACCEPT=0
[[ "${1:-}" == "--accept" ]] && ACCEPT=1

if ! command -v "$JANKURAI" >/dev/null 2>&1; then
  echo "[ratchet] jankurai not on PATH; skipping local enforcement (CI installs it)" >&2
  exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
CUR="$WORK/repo-score.json"
# Audit a CLEAN snapshot of the COMMITTED+STAGED state (HEAD + index) rather
# than the live working tree. `git write-tree` materializes the index as a tree;
# `git archive` of that tree carries HEAD plus anything staged, but EXCLUDES
# unstaged edits and untracked files. This makes the ratchet reproducible — a
# co-worker's uncommitted WIP in the shared checkout can no longer cross-block
# (or mask) this run. Falls back to auditing `.` if this is not a git repo or
# write-tree fails (e.g. detached/bare edge cases).
SNAP="."
if git rev-parse --git-dir >/dev/null 2>&1; then
  TREE="$(git write-tree 2>/dev/null)" || TREE=""
  if [[ -n "$TREE" ]]; then
    SNAP="$WORK/snapshot"
    mkdir -p "$SNAP"
    if ! { git archive --format=tar "$TREE" | tar -x -C "$SNAP"; }; then
      echo "[ratchet] snapshot failed; auditing working tree instead" >&2
      SNAP="."
    fi
  fi
fi

# --full forces a complete (non-incremental) scan. Without it, jankurai's
# [smart] mode may decide "no changes" against an unrelated cache and skip
# writing the --json report (→ FileNotFound) or emit a partial score; --full
# makes the ratchet deterministic and reproducible on every checkout/runner.
"$JANKURAI" audit "$SNAP" --mode "$MODE" --full --json "$CUR" --md "$WORK/repo-score.md" >/dev/null 2>&1 \
  || { echo "[ratchet] jankurai audit failed to run" >&2; exit 1; }

write_summary() {
  cargo run -q -p jmcp-ci-tools -- jankurai-summary "$1" "$2"
}

if [[ "$ACCEPT" == "1" ]]; then
  write_summary "$CUR" "$BASELINE"
  echo "[ratchet] baseline accepted from current audit -> $BASELINE"
  exit 0
fi

if [[ ! -f "$BASELINE" ]]; then
  echo "[ratchet] no baseline ($BASELINE); seeding from current audit" >&2
  write_summary "$CUR" "$BASELINE"
  exit 0
fi

cargo run -q -p jmcp-ci-tools -- jankurai-ratchet "$BASELINE" "$CUR"
