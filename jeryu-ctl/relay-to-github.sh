#!/usr/bin/env bash
# jeryu-ctl/relay-to-github.sh — manual relay: push a jeryu-main commit
# to the repo's GitHub mirror on a relay branch and open a PR there.
#
# This is not part of the autonomous Jeryu green gate. Automated polling mirrors
# directly to GitHub main through mirror-to-github-main.sh. This script is inert
# unless a human passes --manual or sets ALLOW_MANUAL_RELAY=1.
#
# Usage: relay-to-github.sh <jeryu_owner> <jeryu_repo> <sha> <github_slug> [--manual] [--draft]
#   e.g. relay-to-github.sh jeryu veox-proofs <sha> neverhuman/veox-proofs
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; . "$HERE/lib.sh"
OWNER="${1:?jeryu_owner}"; REPO="${2:?jeryu_repo}"; SHA="${3:?sha}"; SLUG="${4:?github_slug}"; shift 4
DRAFT=""; MANUAL=0
while [[ $# -gt 0 ]]; do case "$1" in
  --draft) DRAFT="--draft" ;;
  --manual) MANUAL=1 ;;
  *) die "unknown arg: $1" ;;
esac; shift; done
[[ "$MANUAL" == "1" || "${ALLOW_MANUAL_RELAY:-0}" == "1" ]] \
  || die "GitHub relay is manual-only; pass --manual or set ALLOW_MANUAL_RELAY=1"
bare="$(bare_path "$OWNER" "$REPO")"; [[ -d "$bare" ]] || die "no bare repo: $bare"
guard_no_insteadof                       # never let a 2224/gitea rewrite hijack this push
tok="$(github_token)"; [[ -n "$tok" ]] || die "no github token (GH_RELAY_TOKEN or gh auth)"
short="${SHA:0:12}"; branch="jeryu-relay/$short"
url="https://github.com/${SLUG}.git"

# Idempotent: skip if a PR for this relay branch already exists.
if gh pr list --repo "$SLUG" --head "$branch" --state open --json number --jq '.[0].number' 2>/dev/null | grep -q '[0-9]'; then
  ok "relay PR for $branch already open on $SLUG — skipping"; exit 0
fi
say "relaying $OWNER/$REPO@$short -> github.com/$SLUG ($branch)"
git -C "$bare" -c "http.https://github.com/.extraheader=AUTHORIZATION: bearer ${tok}" \
  push "$url" "$SHA:refs/heads/$branch" 2>&1 | tail -3 || die "relay push failed"
gh pr create --repo "$SLUG" --base main --head "$branch" $DRAFT \
  --title "jeryu relay: $short" \
  --body "Manual relay of jeryu-merged commit \`$SHA\`. Jeryu-local checks remain the source of truth." \
  2>&1 | tail -2 || warn "gh pr create returned non-zero (branch pushed; PR may already exist)"
ok "relay complete: $SLUG $branch"
