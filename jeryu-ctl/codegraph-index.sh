#!/usr/bin/env bash
# jeryu-ctl/codegraph-index.sh — refresh the code graph after a merge (Cluster 3.1).
#
# Worktrees the merged sha off the BARE repo and runs the BUILT jeryu-codegraph CLI to rebuild
# ~/.jeryu/codegraph/<owner>__<repo>.sqlite, so impact analysis (and the agent context-lock in
# Cluster 3.2/3.3) is always fresh. Only cargo-workspace repos. FAIL-OPEN — a stale/failed index
# NEVER blocks a merge. Calls the existing CLI; touches NO jeryu source.
#
# usage: codegraph-index.sh <owner> <repo> <merged_sha> [repo_path]
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; . "$HERE/lib.sh"
OWNER="${1:?owner}"; REPO="${2:?repo}"; SHA="${3:?merged_sha}"
CG="${JERYU_CODEGRAPH_BIN:-$HOME/jeryu/target/debug/jeryu-codegraph}"
[[ -x "$CG" ]] || { warn "codegraph-index: no jeryu-codegraph binary ($CG) — skip"; exit 0; }
bare="$(bare_path "$OWNER" "$REPO")"; [[ -d "$bare" ]] || { warn "codegraph-index: no bare $bare — skip"; exit 0; }
# cargo-workspace guard (index walks workspace members; a non-workspace repo has nothing to index)
git -C "$bare" cat-file -p "$SHA:Cargo.toml" 2>/dev/null | grep -qE '^\[workspace\]' \
  || { say "codegraph-index: $OWNER/$REPO not a cargo workspace at ${SHA:0:12} — skip"; exit 0; }
DBDIR="${JERYU_CODEGRAPH_DIR:-/home/ubuntu/.jeryu/codegraph}"; mkdir -p "$DBDIR" 2>/dev/null || true
DB="$DBDIR/${OWNER}__${REPO}.sqlite"
tmp="$(mktemp -d)"; wt="$tmp/wt"
cleanup(){ git -C "$bare" worktree remove -f "$wt" >/dev/null 2>&1 || true; rm -rf "$tmp" 2>/dev/null || true; }
trap cleanup EXIT
git -c filter.git-crypt.smudge=cat -c filter.git-crypt.required=false \
  -C "$bare" worktree add -f --detach "$wt" "$SHA" >/dev/null 2>&1 || { warn "codegraph-index: worktree add failed"; exit 0; }
if "$CG" index --root "$wt" --db "$DB" >/dev/null 2>&1; then
  ok "codegraph-index: $OWNER/$REPO @ ${SHA:0:12} -> $DB ($("$CG" validate --db "$DB" 2>&1 | tr '\n' ' ' | head -c 80))"
else
  warn "codegraph-index: index failed for $OWNER/$REPO @ ${SHA:0:12} (non-blocking)"
fi
