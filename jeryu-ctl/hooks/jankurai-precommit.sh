#!/usr/bin/env bash
# jankurai pre-commit gate (Cluster 4.2) — blocks a commit that introduces jankurai hard findings or
# new caps in the staged change (diff-scoped via `jankurai diff-audit`; unrelated WIP is not punished).
# Warm repos audit in ~5s; a cold/slow repo degrades to ADVISORY (warn + allow) past the timeout so a
# commit is never hung. Writes ONLY to a temp dir. Bypass: JANKURAI_SKIP_HOOKS=1 or git commit --no-verify.
set -uo pipefail
[[ "${JANKURAI_SKIP_HOOKS:-0}" == "1" ]] && exit 0
command -v jankurai >/dev/null 2>&1 || exit 0
repo="$(git rev-parse --show-toplevel 2>/dev/null)" || exit 0
base="${JANKURAI_DIFF_BASE:-HEAD}"
git -C "$repo" rev-parse --verify -q "$base" >/dev/null 2>&1 || exit 0
to="${JANKURAI_HOOK_TIMEOUT:-60}"
out="$(mktemp -d)"; trap 'rm -rf "$out"' EXIT
timeout "$to" jankurai diff-audit "$repo" --base-ref "$base" --out-dir "$out" --skip-proof >/dev/null 2>"$out/err"; rc=$?
[[ $rc == 0 ]] && exit 0
if [[ $rc == 124 ]]; then
  echo "⚠ jankurai gate skipped: diff-audit exceeded ${to}s (cold cache?). Commit allowed; run 'jankurai diff-audit' before pushing." >&2
  exit 0
fi
echo "" >&2
echo "✗ jankurai gate BLOCKED this commit: hard findings or new caps in the staged change." >&2
[[ -s "$out/diff-audit.md" ]] && { echo "  --- jankurai diff-audit ---" >&2; sed -n '1,22p' "$out/diff-audit.md" >&2; }
[[ -s "$out/err" ]] && sed -n '1,6p' "$out/err" >&2
echo "  → fix the findings, or bypass: JANKURAI_SKIP_HOOKS=1 git commit   (or: git commit --no-verify)" >&2
exit 1
