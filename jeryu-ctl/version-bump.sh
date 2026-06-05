#!/usr/bin/env bash
# jeryu-ctl/version-bump.sh — LIVE auto-versioning (Cluster 1A).
#
# After the gated FF-merge advances main to <merged_sha>, auto-bump the workspace version
# using the BUILT jeryu-wsversion engine (conventional commits: feat->minor, breaking->major,
# else patch). Commit it `[skip-version]` so the loop never re-triggers, advance main to the
# bump commit via server-side update-ref (the same mechanism automerge uses), CARRY-FORWARD
# jeryu/ci + jeryu/agent-review onto the bump commit (it == the gated tree + a version/CHANGELOG
# edit; the post-merge release build re-validates the bumped tree), tag vX.Y.Z, write a .version
# sidecar next to the signed receipt for the universe board.
#
# usage: version-bump.sh <owner> <repo> <merged_sha> <bare> <prev_main>
# Prints the new version to stdout on a real bump; prints nothing + exits 0 on no-op.
# FAIL-OPEN: any error -> exit 0 (the merge already happened; NEVER block/regress the loop).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; . "$HERE/lib.sh"
OWNER="${1:?owner}"; REPO="${2:?repo}"; SHA="${3:?merged_sha}"; BARE="${4:?bare}"; PREV="${5:-}"

WSVERSION_BIN="${WSVERSION_BIN:-$HOME/jeryu/target/debug/jeryu-wsversion}"
[[ -x "$WSVERSION_BIN" ]] || { warn "version-bump: no wsversion binary ($WSVERSION_BIN) — skip"; exit 0; }
[[ -d "$BARE" ]] || { warn "version-bump: no bare repo $BARE — skip"; exit 0; }

# Guard 1 (recursion): the merged commit is itself a [skip-version] bump.
subj="$(git -C "$BARE" log -1 --format=%s "$SHA" 2>/dev/null || true)"
[[ "$subj" == *'[skip-version]'* ]] && exit 0

# Guard 2 (applicability): only repos with a root [workspace.package].version (no-op elsewhere).
git -C "$BARE" cat-file -p "$SHA:Cargo.toml" 2>/dev/null | grep -q '\[workspace\.package\]' || exit 0

# Guard 3 (single-writer): defend against --parallel / manual overlap.
# (Open fd 9 WITHOUT touching stderr — `exec 9>f 2>/dev/null` would silence the whole script.)
lock="/home/ubuntu/.jeryu/version-bump-${OWNER}__${REPO}.lock"; mkdir -p "$(dirname "$lock")" 2>/dev/null || true
if ! exec 9>"$lock"; then warn "version-bump: cannot open lock $lock — skip"; exit 0; fi
flock -n 9 || { warn "version-bump: $OWNER/$REPO locked — skip"; exit 0; }

# Commit range = pre-merge main .. merged sha (the PR's commits). Fallback if prev unknown.
range="${PREV}..${SHA}"
if [[ -z "$PREV" ]] || ! git -C "$BARE" cat-file -e "${PREV}^{commit}" 2>/dev/null; then
  git -C "$BARE" cat-file -e "${SHA}~1^{commit}" 2>/dev/null && range="${SHA}~1..${SHA}" || exit 0
fi

# Worktree off the BARE repo: commits land in the bare's object store, so update-ref can then
# advance main (a worktree off the working-copy would write objects elsewhere + main is push-denied).
tmp="$(mktemp -d)"; wt="$tmp/wt"
cleanup(){ git -C "$BARE" worktree remove -f "$wt" >/dev/null 2>&1 || true; rm -rf "$tmp" 2>/dev/null || true; }
trap cleanup EXIT
git -c filter.git-crypt.smudge=cat -c filter.git-crypt.required=false \
  -C "$BARE" worktree add -f --detach "$wt" "$SHA" >/dev/null 2>&1 || { warn "version-bump: worktree add failed"; exit 0; }

# Decide (fast, pure conventional-commit classification).
dec="$("$WSVERSION_BIN" --root "$wt" decide --range "$range" --json 2>/dev/null || true)"
read -r FROM TO BUMP SKIP < <(printf '%s' "$dec" | python3 -c '
import sys, json
try: d = json.load(sys.stdin)
except Exception: sys.exit(0)
print(d.get("from",""), d.get("to",""), d.get("bump",""), str(d.get("skipped", False)).lower())
' 2>/dev/null)
[[ -z "${TO:-}" || "${SKIP:-}" == "true" || "$TO" == "${FROM:-}" ]] && exit 0

# Apply (rewrites root Cargo.toml [workspace.package].version + rolls CHANGELOG). The engine REQUIRES
# a CHANGELOG.md — seed a minimal one for repos that lack it (auto-changelog is a welcome side effect).
# Stage ONLY the files it touches (git-crypt-safe: never `add -A`, which would re-stage smudge=cat'd crypt files).
[[ -f "$wt/CHANGELOG.md" ]] || printf '# Changelog\n\n## Unreleased\n' > "$wt/CHANGELOG.md"
"$WSVERSION_BIN" --root "$wt" apply --range "$range" >/dev/null 2>&1 || { warn "version-bump: apply failed"; exit 0; }
git -C "$wt" add Cargo.toml 2>/dev/null || true
[[ -f "$wt/CHANGELOG.md" ]] && git -C "$wt" add CHANGELOG.md 2>/dev/null || true
git -C "$wt" diff --cached --quiet && { warn "version-bump: apply produced no staged change — skip"; exit 0; }
git -C "$wt" -c user.email=forge@jeryu.local -c user.name=jeryu-forge \
  commit -q -m "chore(release): v${TO} [skip-version]" || { warn "version-bump: commit failed"; exit 0; }
BUMP_SHA="$(git -C "$wt" rev-parse HEAD)"

# Advance main ONLY if it is still exactly at SHA (no concurrent advance) — server-side update-ref.
[[ "$(git -C "$BARE" rev-parse --verify refs/heads/main 2>/dev/null)" == "$SHA" ]] \
  || { warn "version-bump: main moved off ${SHA:0:12} — abort bump"; exit 0; }
git -C "$BARE" update-ref refs/heads/main "$BUMP_SHA" || { warn "version-bump: update-ref failed"; exit 0; }

# Carry the gate forward onto the bump commit so the repo stays 4-green (the deploy build re-validates).
post_check "$OWNER" "$REPO" "$BUMP_SHA" "jeryu/ci" success || true
post_check "$OWNER" "$REPO" "$BUMP_SHA" "jeryu/agent-review" success || true
post_check "$OWNER" "$REPO" "$BUMP_SHA" "jeryu/merge" success || true

# Surfacing: local tag + a .version sidecar next to the signed receipts (universe board reads it).
git -C "$BARE" tag -f "v${TO}" "$BUMP_SHA" >/dev/null 2>&1 || true
store="${SIGNRAIL_STORE_ROOT:-/home/ubuntu/.local/share/jeryu/signrail}"
mkdir -p "$store/releases" 2>/dev/null || true
printf '%s\n' "$TO" > "$store/releases/${OWNER}_${REPO}@${BUMP_SHA}.version" 2>/dev/null || true

ok "version-bump: $OWNER/$REPO ${FROM} -> v${TO} (${BUMP}) @ ${BUMP_SHA:0:12}"
printf '%s' "$TO"
