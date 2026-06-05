#!/usr/bin/env bash
# jeryu-ctl/release-promotion.sh — post-merge SIGNED artifact pipeline (canonical path).
#
# Drives Codex's SignRail lane (the repo's generated `ops/ci/artifact_support.sh`) host-native at
# a merged sha: build → SignRail Ed25519 sign → emit release/sbom/provenance/witness +
# stage-receipts {local,dev-canary,prod}. This is "local" signing on jeryu; the REMOTE half is
# GitHub's artifact-support workflow (uses the `SIGNRAIL_ED25519_SEED` repo secret).
#
# usage: release-promotion.sh <jeryu_owner> <repo> <merged_sha> [repo_path]
# env:   JERYU_SIGNRAIL_ED25519_SEED  (signing seed; if unset, falls back to the existing
#        ~/.jeryu/secrets/signing.env JERYU_MR_ED25519_SEED_HEX — pending Codex's seed decision)
#        SIGNRAIL_STORE_ROOT          (default ~/.local/share/jeryu/signrail)
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; . "$HERE/lib.sh"; . "$HERE/manifest.sh"
OWNER="${1:?owner}"; REPO="${2:?repo}"; SHA="${3:?merged_sha}"; REPO_PATH="${4:-}"
[[ -n "$REPO_PATH" ]] || REPO_PATH="$(manifest_repos --rows | awk -F'|' -v n="$REPO" '$1==n{print $2}')"
[[ -e "$REPO_PATH/.git" ]] || die "repo path not found for $REPO (pass as \$4): $REPO_PATH"
GITHUB_SLUG="$(manifest_repos --rows | awk -F'|' -v js="$OWNER/$REPO" '$4==js{print $3; exit}')"
[[ -n "$GITHUB_SLUG" ]] && export GITHUB_REPOSITORY="${GITHUB_REPOSITORY:-$GITHUB_SLUG}"

# Signing seed: explicit env wins; else reuse the existing host Ed25519 seed (not committed anywhere).
if [[ -z "${JERYU_SIGNRAIL_ED25519_SEED:-}" && -r /home/ubuntu/.jeryu/secrets/signing.env ]]; then
  JERYU_SIGNRAIL_ED25519_SEED="$(. /home/ubuntu/.jeryu/secrets/signing.env 2>/dev/null; printf '%s' "${JERYU_MR_ED25519_SEED_HEX:-}")"
fi
[[ -n "${JERYU_SIGNRAIL_ED25519_SEED:-}" ]] || die "no signing seed (set JERYU_SIGNRAIL_ED25519_SEED or signing.env)"
export JERYU_SIGNRAIL_ED25519_SEED
export SIGNRAIL_STORE_ROOT="${SIGNRAIL_STORE_ROOT:-/home/ubuntu/.local/share/jeryu/signrail}"

git -C "$REPO_PATH" cat-file -e "$SHA^{commit}" 2>/dev/null || git -C "$REPO_PATH" fetch -q jeryu 2>/dev/null || true
tmp="$(mktemp -d)"; wt="$tmp/$REPO"
git -c filter.git-crypt.smudge=cat -c filter.git-crypt.required=false \
  -C "$REPO_PATH" worktree add -f --detach "$wt" "$SHA" >/dev/null 2>&1 || die "worktree checkout failed for $SHA"
cleanup(){ git -C "$REPO_PATH" worktree remove -f "$wt" >/dev/null 2>&1 || true; rmdir "$tmp" 2>/dev/null || true; }
trap cleanup EXIT

log="${JERYU_CTL_STATE}/${OWNER}__${REPO}/${SHA}.release.log"; mkdir -p "$(dirname "$log")"
# Autonomous canary→prod EVIDENCE GATE: foundry → canary rings → nightwatch (LLM prod gate).
# Grants prod only on a conformant nightwatch `pass`; posts jeryu/promote. Fail-closed.
promote_gate(){
  [[ -x "$HERE/autonomy-deploy.sh" ]] || { warn "no autonomy-deploy.sh — skipping prod gate"; return 0; }
  say "release-promotion: handing off to autonomy-deploy evidence gate"
  "$HERE/autonomy-deploy.sh" "$OWNER" "$REPO" "$SHA" "$wt" >>"${log%.release.log}.promote.log" 2>&1 \
    && ok "autonomy-deploy: prod gate evaluated (see jeryu/promote)" \
    || warn "autonomy-deploy gate denied or errored (see ${log%.release.log}.promote.log)"
}

validate_signrail_receipts(){
  local sr="$1"
  python3 - "$sr" "$SHA" <<'PY'
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
sha = sys.argv[2]
missing = []
bad = []
for stage in ("local", "dev-canary", "prod"):
    path = root / "stage-receipts" / f"{stage}.json"
    if not path.is_file():
        missing.append(stage)
        continue
    try:
        data = json.loads(path.read_text())
    except Exception as exc:
        bad.append(f"{stage}:unreadable:{exc}")
        continue
    payload = data.get("payload") or {}
    if payload.get("stage") != stage:
        bad.append(f"{stage}:stage")
    if payload.get("sha") != sha:
        bad.append(f"{stage}:sha")
    if payload.get("signature_coverage_percent") != 100:
        bad.append(f"{stage}:coverage={payload.get('signature_coverage_percent')}")
if missing or bad:
    print("missing=" + ",".join(missing) + " bad=" + ",".join(bad))
    raise SystemExit(1)
print("local,dev-canary,prod coverage=100")
PY
}

if [[ -x "$wt/ops/ci/artifact_support.sh" ]]; then
  # WAVE-1: SignRail signs the real artifact + emits stage-receipts {local,dev-canary,prod}.
  say "release-promotion: $OWNER/$REPO@${SHA:0:12} → SignRail artifact_support (host-native)"
  if ( cd "$wt" && WORKERS="${WORKERS:-40}" bash ops/ci/artifact_support.sh "${WORKERS:-40}" ) >"$log" 2>&1; then
    sr="$wt/target/artifact-support/signrail"
    receipt_status="$(validate_signrail_receipts "$sr" 2>>"$log")" || {
      warn "release-promotion FAILED: invalid SignRail stage receipts ($receipt_status; log: $log)"
      post_check "$OWNER" "$REPO" "$SHA" "jeryu/release" failure
      post_check "$OWNER" "$REPO" "$SHA" "jeryu/promote" failure
      echo failure
      exit 0
    }
    cov="$(python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));print(d.get("payload",{}).get("signature_coverage_percent","?"))' "$sr/stage-receipts/prod.json" 2>/dev/null || echo '?')"
    stages="$(ls "$sr/stage-receipts" 2>/dev/null | tr '\n' ' ')"
    ok "release-promotion OK — signed release.json + stage-receipts [$stages] coverage=${cov}% ($receipt_status; log: $log)"
    post_check "$OWNER" "$REPO" "$SHA" "jeryu/release" success
    promote_gate
    echo success
  else
    warn "release-promotion FAILED (see $log)"
    post_check "$OWNER" "$REPO" "$SHA" "jeryu/release" failure
    echo failure
  fi
else
  warn "release-promotion FAILED: $REPO has no ops/ci/artifact_support.sh at $SHA"
  post_check "$OWNER" "$REPO" "$SHA" "jeryu/release" failure
  post_check "$OWNER" "$REPO" "$SHA" "jeryu/promote" failure
  echo failure
fi
