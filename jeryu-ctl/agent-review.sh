#!/usr/bin/env bash
# jeryu-ctl/agent-review.sh — the LLM agent-review merge gate.
#
# Reads the PR diff (base..head) + CI evidence from jeryu, classifies risk, asks a
# real LLM reviewer (claude -p / codex exec) for a verdict, and records it as a
# jeryu check-run named `jeryu/agent-review` (sha-bound). The automerge gate then
# requires BOTH `ci/*` green AND `jeryu/agent-review`=success.
#
# Usage:   agent-review.sh <owner> <repo> <head_sha> [base_branch]
# Env:     REVIEWER=claude|codex (default claude)
#          JERYU_REVIEW_DRY=1     build+print evidence/prompt, no LLM, no check-run
#          AGENT_OVERRIDE_APPROVE=1  human override (records APPROVE without the LLM)
#          DIFF_MAX_LINES=500     diff truncation budget sent to the model
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; . "$HERE/lib.sh"

OWNER="${1:?owner}"; REPO="${2:?repo}"; SHA="${3:?head_sha}"; BASE="${4:-main}"
REVIEWER="${REVIEWER:-claude}"; DIFF_MAX_LINES="${DIFF_MAX_LINES:-500}"
bare="$(bare_path "$OWNER" "$REPO")"
[[ -d "$bare" ]] || die "no bare repo on jeryu: $bare"
j_health || die "jeryu server not healthy at $JERYU_BASE"

# --- evidence: diff range, changed files, risk tier, CI status ---------------
if mb="$(git -C "$bare" merge-base "refs/heads/$BASE" "$SHA" 2>/dev/null)" && [[ -n "$mb" ]]; then
  range="$mb..$SHA"
else
  range="$SHA^..$SHA"   # first-commit / no common base
fi
changed="$(git -C "$bare" diff --name-only "$range" 2>/dev/null)"
diff_body="$(git -C "$bare" diff "$range" 2>/dev/null | head -n "$DIFF_MAX_LINES")"
diff_sha="$(git -C "$bare" diff "$range" 2>/dev/null | sha256sum | cut -d' ' -f1)"

risk="R0"
if printf '%s\n' "$changed" | grep -qiE '^\.github/|^\.jeryu/|^ops/ci|Cargo\.lock|secret|signing|crypto|/auth|\.key$|\.pem$'; then
  risk="R5"
fi
REQUIRED_CHECK="${REQUIRED_CHECK:-jeryu/ci}"   # the host-native CI check (jeryu's hermetic ci/ci is ignored)
if [[ "$(check_conclusion "$OWNER" "$REPO" "$SHA" "$REQUIRED_CHECK")" == "success" ]]; then ci_status="green"; else ci_status="not-green"; fi

# --- idempotency: reuse a prior verdict for the same sha+diff ----------------
side_dir="$JERYU_CTL_STATE/${OWNER}__${REPO}"; mkdir -p "$side_dir"
side="$side_dir/$SHA.json"
if [[ "${AGENT_OVERRIDE_APPROVE:-0}" != "1" ]] && [[ -f "$side" ]] && [[ "$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("diff_sha256",""))' "$side" 2>/dev/null)" == "$diff_sha" ]]; then
  v="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("verdict",""))' "$side")"
  say "idempotent: reusing prior verdict $v for $OWNER/$REPO@$SHA"
  [[ "$v" == "APPROVE" ]] && post_check "$OWNER" "$REPO" "$SHA" "jeryu/agent-review" success \
                          || post_check "$OWNER" "$REPO" "$SHA" "jeryu/agent-review" failure
  echo "$v"; exit 0
fi

read -r -d '' PROMPT <<EOF || true
You are a careful automated code reviewer gating an AUTO-MERGE into the protected
main branch of ${OWNER}/${REPO}.

Commit: ${SHA}   (diff range ${range} vs ${BASE})
CI status (jeryu ci/* checks): ${ci_status}
Risk tier (changed-path heuristic): ${risk}
Changed files:
${changed}

Approve if the change is correct, safe, and complete and CI is green. Only
REQUEST_CHANGES for a concrete problem you can name (a bug, an unsafe or
incomplete change, or CI not green). Do not reject trivially-correct changes.

Respond with EXACTLY one line beginning either:
  VERDICT: APPROVE
  VERDICT: REQUEST_CHANGES
then a one-sentence reason.

----- DIFF (truncated to ${DIFF_MAX_LINES} lines) -----
${diff_body}
EOF

if [[ "${JERYU_REVIEW_DRY:-0}" == "1" ]]; then
  say "DRY RUN — evidence for $OWNER/$REPO@$SHA: risk=$risk ci=$ci_status reviewer=$REVIEWER diff_sha=${diff_sha:0:12}"
  printf '%s\n' "$PROMPT"
  exit 0
fi

verdict="REQUEST_CHANGES"; reason=""; model="$REVIEWER"
if [[ "${AGENT_OVERRIDE_APPROVE:-0}" == "1" ]]; then
  verdict="APPROVE"; reason="human override (AGENT_OVERRIDE_APPROVE=1)"; model="human-override"
elif [[ "$risk" == "R5" ]]; then
  verdict="REQUEST_CHANGES"; reason="R5 risk paths (.github/.jeryu/ops-ci/lockfile/secrets) require human approval"; model="risk-gate"
  warn "R5 fail-closed: not invoking LLM; human approval required"
else
  pf="$(mktemp)"; printf '%s' "$PROMPT" > "$pf"
  say "invoking $REVIEWER reviewer for $OWNER/$REPO@$SHA (risk=$risk ci=$ci_status) ..."
  case "$REVIEWER" in
    codex)  out="$(timeout 240 codex exec "$(cat "$pf")" 2>/dev/null)" ;;
    *)      out="$(timeout 240 claude -p "$(cat "$pf")" 2>/dev/null)" ;;
  esac
  rm -f "$pf"
  printf '%s' "$out" > "$side_dir/$SHA.raw" 2>/dev/null || true
  if printf '%s' "$out" | grep -qiE 'VERDICT:[[:space:]]*APPROVE'; then verdict="APPROVE"
  elif printf '%s' "$out" | grep -qiE 'VERDICT:[[:space:]]*REQUEST_CHANGES'; then verdict="REQUEST_CHANGES"
  else verdict="REQUEST_CHANGES"; fi
  reason="$(printf '%s' "$out" | grep -iE 'VERDICT:' | head -1 | sed -E 's/.*VERDICT:[[:space:]]*(APPROVE|REQUEST_CHANGES)[[:space:]]*//I')"
  [[ -z "$reason" ]] && reason="$(printf '%s' "$out" | tail -1)"
fi

python3 - "$side" "$OWNER" "$REPO" "$SHA" "$BASE" "$verdict" "$model" "$risk" "$ci_status" "$diff_sha" "$reason" <<'PY'
import json, sys, datetime
side, owner, repo, sha, base, verdict, reviewer, risk, ci, diff_sha, reason = sys.argv[1:12]
d = dict(owner=owner, repo=repo, head_sha=sha, base=base, verdict=verdict,
         reviewer=reviewer, risk=risk, ci=ci, diff_sha256=diff_sha, reason=reason,
         created_at=datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))
json.dump(d, open(side, "w"), indent=1)
PY

[[ "$verdict" == "APPROVE" ]] && post_check "$OWNER" "$REPO" "$SHA" "jeryu/agent-review" success \
                              || post_check "$OWNER" "$REPO" "$SHA" "jeryu/agent-review" failure
ok "verdict=$verdict reviewer=$model risk=$risk ci=$ci_status -> jeryu/agent-review recorded"
echo "$verdict"
