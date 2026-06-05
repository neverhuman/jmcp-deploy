#!/usr/bin/env bash
# jeryu-ctl/onboard-repo.sh — bring a manifest repo onto jeryu (wave-2), PR-only + autonomy-ready.
#
# Mechanics I own: dead-gitea origin fix → create on jeryu → github+jeryu remotes → flip origin internal →
# seed local refs/heads/main → install the deny-main PR-only hook. CI scaffold (.jeryu) + autonomy policy (.autonomy) are
# the generator's lane (Codex) — this script flags repos that lack them rather than fabricating policy.
#
# usage: onboard-repo.sh <name>   (name must exist in repos.manifest.toml)
#        onboard-repo.sh <name> --no-push   (skip the seed push)
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; . "$HERE/lib.sh"; . "$HERE/manifest.sh"
NAME="${1:?repo name}"; NOPUSH=""; [[ "${2:-}" == "--no-push" ]] && NOPUSH=1
row="$(manifest_repos --rows | awk -F'|' -v n="$NAME" '$1==n{print; exit}')"
[[ -n "$row" ]] || die "no manifest entry for '$NAME'"
IFS='|' read -r name path github_slug jeryu_slug <<<"$row"
[[ -d "$path/.git" ]] || die "not a git repo: $path"
owner="${jeryu_slug%%/*}"; jname="${jeryu_slug#*/}"
j_health || die "jeryu not healthy at $JERYU_BASE"
guard_no_insteadof

# 1. Fix a dead-gitea origin (e.g. jankurai's ssh://127.0.0.1:2224) before anything else.
cur="$(git -C "$path" remote get-url origin 2>/dev/null || echo '')"
if [[ "$cur" == *127.0.0.1:2224* || "$cur" == *gitea* ]]; then
  git -C "$path" remote set-url origin "https://github.com/$github_slug.git"
  ok "$NAME: repointed dead-gitea origin -> https://github.com/$github_slug.git"
fi

# 2. Create on jeryu + github/jeryu remotes + flip origin internal + seed from local main (reuses onboard.sh).
if [[ -n "$NOPUSH" ]]; then "$HERE/onboard.sh" "$path" "$jeryu_slug" --flip-origin
else "$HERE/onboard.sh" "$path" "$jeryu_slug" --flip-origin --push; fi

# 3. Install the deny-main PR-only hook on the bare repo.
bare="$(bare_path "$owner" "$jname")"
if [[ -d "$bare" ]]; then
  cp "$HERE/hooks/pre-receive" "$bare/hooks/pre-receive" && chmod +x "$bare/hooks/pre-receive"
  ok "$NAME: deny-main PR-only hook installed at $bare/hooks/pre-receive"
else
  warn "$NAME: bare repo not found at $bare — hook NOT installed"
fi

# 4. Flag generator-lane gaps (coordinate with Codex; do not fabricate policy).
[[ -d "$path/.jeryu"     ]] || warn "$NAME: no .jeryu/ CI scaffold — needs generator (Codex) before host-ci can run its lanes"
[[ -d "$path/.autonomy"  ]] || warn "$NAME: no .autonomy/ policy — needs the autonomy policy bundle before canary/prod gates"
[[ -x "$path/ci-fast-push.sh" ]] || warn "$NAME: no ci-fast-push.sh — host-ci has nothing to run yet"

ok "$NAME registered -> $jeryu_slug (origin internal, github backup, deny-main hook). Flip manifest onboarded=true only after loop+deploy+SignRail receipts are verified."
