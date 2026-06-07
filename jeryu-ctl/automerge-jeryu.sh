#!/usr/bin/env bash
# jeryu-ctl/automerge-jeryu.sh — the jeryu-side auto-merge gate (extends the proven
# host poller). For each open PR into main on jeryu: require BOTH jeryu/ci green AND
# jeryu/agent-review=success for the SAME head sha, and no opt-out label, then
# advance main via server-side update-ref (the only automated path that moves jeryu main).
# The --relay path is manual-only; jeryu-poll uses --mirror-github instead.
#
# Usage:
#   automerge-jeryu.sh <owner> <repo> [--relay <github_slug>] [--review]
#     --review  run agent-review.sh first if the gate's agent check is missing
#     --relay   manual option: after merge, open a GitHub relay PR
#               requires ALLOW_MANUAL_RELAY=1
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; . "$HERE/lib.sh"

OWNER="${1:?owner}"; REPO="${2:?repo}"; shift 2
RELAY_SLUG=""; DO_REVIEW=0; DEPLOY=0
while [[ $# -gt 0 ]]; do case "$1" in
  --relay) shift; RELAY_SLUG="${1:-}";;
  --review) DO_REVIEW=1;;
  --deploy) DEPLOY=1;;   # after merge, fire the post-merge signed deployment (background)
  *) die "unknown arg: $1";;
esac; shift; done
# Required CI check = the one host-ci.sh posts (host-native execution). jeryu's
# in-process bridge check `ci/ci` is hermetic and ignored here.
REQUIRED_CHECK="${REQUIRED_CHECK:-jeryu/ci}"
if [[ -n "$RELAY_SLUG" && "${ALLOW_MANUAL_RELAY:-0}" != "1" ]]; then
  die "--relay is manual-only; set ALLOW_MANUAL_RELAY=1 or use jeryu-poll.sh --mirror-github"
fi

bare="$(bare_path "$OWNER" "$REPO")"; [[ -d "$bare" ]] || die "no bare repo: $bare"
j_health || die "jeryu not healthy at $JERYU_BASE"

# Open PRs into main. jeryu PR records carry a placeholder head.sha, so we resolve
# the REAL commit sha from the bare repo's branch ref.
pulls="$(curl -fsS --max-time 10 "$JERYU_BASE/repos/$OWNER/$REPO/pulls?state=open" 2>/dev/null)"
mapfile -t ROWS < <(printf '%s' "$pulls" | python3 -c '
import sys, json
try: d = json.load(sys.stdin)
except json.JSONDecodeError: sys.exit(0)  # empty/non-JSON body => no eligible PRs
for p in (d if isinstance(d, list) else d.get("items", [])):
    if p.get("state") != "open" or p.get("draft"): continue
    base = (p.get("base") or {}).get("ref"); head = (p.get("head") or {}).get("ref")
    if base != "main" or not head: continue
    labels = [l.get("name","") if isinstance(l,dict) else str(l) for l in (p.get("labels") or [])]
    if any(x in ("hold","do-not-merge","wip") for x in labels): continue
    print("%s|%s" % (p.get("number"), head))
')
[[ ${#ROWS[@]} -gt 0 ]] || { say "$OWNER/$REPO: no eligible open PRs into main"; exit 0; }

for row in "${ROWS[@]}"; do
  num="${row%%|*}"; head_ref="${row#*|}"
  head_sha="$(git -C "$bare" rev-parse --verify "refs/heads/$head_ref" 2>/dev/null)" || { warn "PR#$num: head ref $head_ref not in bare repo"; continue; }

  if [[ "$DO_REVIEW" == "1" && "$(check_conclusion "$OWNER" "$REPO" "$head_sha" jeryu/agent-review)" != "success" ]]; then
    "$HERE/agent-review.sh" "$OWNER" "$REPO" "$head_sha" main >/dev/null 2>&1 || true
  fi

  if [[ "$(check_conclusion "$OWNER" "$REPO" "$head_sha" "$REQUIRED_CHECK")" != "success" ]]; then
    say "PR#$num ($head_ref): $REQUIRED_CHECK not success — skip"; continue; fi
  if [[ "$(check_conclusion "$OWNER" "$REPO" "$head_sha" jeryu/agent-review)" != "success" ]]; then
    say "PR#$num ($head_ref): jeryu/agent-review not approved — skip"; continue; fi
  if ! git -C "$bare" merge-base --is-ancestor refs/heads/main "$head_sha" 2>/dev/null; then
    post_check "$OWNER" "$REPO" "$head_sha" "jeryu/merge" failure || true
    warn "PR#$num ($head_ref): not fast-forwardable onto main (needs rebase) — skip"; continue; fi

  say "PR#$num ($head_ref): both gates green -> fast-forward main to ${head_sha:0:12}"
  # main is PR-only over the wire (pre-receive hook denies direct pushes); the gated automerge is
  # the sole advancer, via a server-side fast-forward update-ref (already FF-checked above).
  prev_main="$(git -C "$bare" rev-parse --verify refs/heads/main 2>/dev/null)"
  if git -C "$bare" update-ref refs/heads/main "$head_sha"; then
    post_check "$OWNER" "$REPO" "$head_sha" "jeryu/merge" success || true
    curl -fsS --max-time 10 -X PUT "$JERYU_BASE/repos/$OWNER/$REPO/pulls/$num/merge" \
      -H 'content-type: application/json' -d '{"merge_method":"merge"}' >/dev/null 2>&1 || true
    ok "MERGED $OWNER/$REPO#$num -> main @ ${head_sha:0:12}"
    [[ -n "$RELAY_SLUG" ]] && ALLOW_MANUAL_RELAY=1 "$HERE/relay-to-github.sh" "$OWNER" "$REPO" "$head_sha" "$RELAY_SLUG" --manual || true
    # Cluster 1A: live auto-versioning (opt-in via JERYU_AUTOVERSION=1). Advances main to the
    # [skip-version] bump commit + carries the gate forward; the deploy below signs the bumped
    # version. Fail-open (no-op for repos without a [workspace.package].version).
    if [[ "${JERYU_AUTOVERSION:-0}" == "1" ]]; then
      mkdir -p "${JERYU_CTL_STATE}/${OWNER}__${REPO}" 2>/dev/null || true
      nv="$("$HERE/version-bump.sh" "$OWNER" "$REPO" "$head_sha" "$bare" "$prev_main" 2>>"${JERYU_CTL_STATE}/${OWNER}__${REPO}/version-bump.log" || true)"
      if [[ -n "$nv" ]]; then
        head_sha="$(git -C "$bare" rev-parse --verify refs/heads/main)"
        ok "auto-versioned $OWNER/$REPO -> v$nv @ ${head_sha:0:12}"
      fi
    fi
    # autonomous post-merge signed deployment (build -> SignRail sign -> stage-receipts local/dev-canary/prod)
    if [[ "$DEPLOY" == "1" ]]; then
      say "PR#$num: launching post-merge signed deployment (background)"
      nohup "$HERE/release-promotion.sh" "$OWNER" "$REPO" "$head_sha" >>"${JERYU_CTL_STATE}/${OWNER}__${REPO}/deploy.log" 2>&1 &
      disown 2>/dev/null || true
    fi
    # Cluster 3.1: refresh the code graph for this repo (opt-in, background, non-blocking).
    if [[ "${JERYU_CODEGRAPH_INDEX:-0}" == "1" ]]; then
      mkdir -p "${JERYU_CTL_STATE}/${OWNER}__${REPO}" 2>/dev/null || true
      nohup "$HERE/codegraph-index.sh" "$OWNER" "$REPO" "$head_sha" >>"${JERYU_CTL_STATE}/${OWNER}__${REPO}/codegraph.log" 2>&1 &
      disown 2>/dev/null || true
    fi
  else
    post_check "$OWNER" "$REPO" "$head_sha" "jeryu/merge" failure || true
    warn "PR#$num: server-side update-ref to main failed"
  fi
done
