#!/usr/bin/env bash
# jeryu-ctl/autonomy-deploy.sh — the AUTONOMOUS canary→prod EVIDENCE GATE.
#
# Runs jeryu's autonomy evidence-gate chain for a merged, signed commit and grants
# (or denies) PROD promotion, fully autonomously:
#     foundry (Law-6 build-once -> signed ReleasePassport)
#       -> canary start
#       -> canary evaluate loop (repo-owned telemetry: 1% -> 5% -> 25% -> 50% -> 100%)
#       -> nightwatch (LLM runtime reviewer) = the PROD gate
# Prod is granted ONLY if canary reaches the 100% ring AND nightwatch decision == "pass"
# (block/concern/abstain all fail CLOSED). The decision, passport, canary history and
# receipt are persisted as a deploy-evidence bundle, and a `jeryu/promote` check is posted.
#
# This is the EVIDENCE GATE; it runs AFTER release-promotion.sh has built+signed the real
# artifact (SignRail) and posted jeryu/release. SignRail = the artifact; this = the gate.
#
# usage: autonomy-deploy.sh <jeryu_owner> <repo> <merged_sha> [repo_path]
# env:   AUTONOMY_DIR           central bundle (default /home/ubuntu/.jeryu/autonomy)
#        DEPLOY_EVIDENCE_ROOT   default ~/.local/share/jeryu/deploy-evidence
#        NIGHTWATCH_RETRIES     default 3 (LLM can over-run the token cap -> abstain; retry)
#        AUTONOMY_BIN           default ~/.jeryu/bin/autonomy
#        TELEMETRY_MAX_AGE_SECONDS default 900
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; . "$HERE/lib.sh"; . "$HERE/manifest.sh"

OWNER="${1:?owner}"; REPO="${2:?repo}"; SHA="${3:?merged_sha}"; REPO_PATH="${4:-}"
AUTONOMY_BIN="${AUTONOMY_BIN:-/home/ubuntu/.jeryu/bin/autonomy}"
AUTONOMY_DIR="${AUTONOMY_DIR:-/home/ubuntu/.jeryu/autonomy}"
DEPLOY_EVIDENCE_ROOT="${DEPLOY_EVIDENCE_ROOT:-/home/ubuntu/.local/share/jeryu/deploy-evidence}"
NIGHTWATCH_RETRIES="${NIGHTWATCH_RETRIES:-3}"
TELEMETRY_MAX_AGE_SECONDS="${TELEMETRY_MAX_AGE_SECONDS:-900}"
[[ -x "$AUTONOMY_BIN" ]] || die "autonomy binary not found: $AUTONOMY_BIN"
[[ -d "$AUTONOMY_DIR" ]] || die "central .autonomy not found: $AUTONOMY_DIR"
[[ "$SHA" =~ ^[0-9a-f]{40}$ ]] || die "merged_sha must be 40-hex: $SHA"

# Per-deploy ISOLATED ledger: the one-shot CLIs do not append launch_ledger anyway, and the
# live daemon holds the canonical ledger as single-writer — never contend with it.
export JERYU_DATABASE_URL="redline:///tmp/jeryu-deploy-${SHA:0:12}.redline"
# Real signing for the foundry passport (reuse the existing host Ed25519 seed; never committed).
if [[ -z "${JERYU_SIGNRAIL_ED25519_SEED:-}" && -r /home/ubuntu/.jeryu/secrets/signing.env ]]; then
  # shellcheck disable=SC1091
  JERYU_SIGNRAIL_ED25519_SEED="$(. /home/ubuntu/.jeryu/secrets/signing.env 2>/dev/null; printf '%s' "${JERYU_MR_ED25519_SEED_HEX:-}")"
  export JERYU_SIGNRAIL_ED25519_SEED
fi

SYFT="$(command -v syft || true)"; COSIGN="$(command -v cosign || true)"
ev="$DEPLOY_EVIDENCE_ROOT/${OWNER}__${REPO}/${SHA}"; mkdir -p "$ev"
log="${JERYU_CTL_STATE}/${OWNER}__${REPO}/${SHA}.promote.log"; mkdir -p "$(dirname "$log")"
now_rfc3339(){ date -u +%Y-%m-%dT%H:%M:%SZ; }
tele_tmp=""; tele_wt=""
cleanup(){
  if [[ -n "$tele_wt" && -n "$REPO_PATH" ]]; then
    git -C "$REPO_PATH" worktree remove -f "$tele_wt" >/dev/null 2>&1 || true
  fi
  [[ -n "$tele_tmp" ]] && rmdir "$tele_tmp" >/dev/null 2>&1 || true
}
trap cleanup EXIT

deny(){ # <reason>
  warn "PROMOTE DENIED $OWNER/$REPO@${SHA:0:12}: $1"
  python3 - "$ev/decision.json" "$SHA" "deny" "$1" <<'PY' 2>/dev/null || true
import json,sys; json.dump(dict(sha=sys.argv[2],prod_granted=False,outcome=sys.argv[3],reason=sys.argv[4]),open(sys.argv[1],"w"),indent=1)
PY
  post_check "$OWNER" "$REPO" "$SHA" "jeryu/promote" failure || true
  echo deny; exit 0
}

[[ -n "$REPO_PATH" ]] || REPO_PATH="$(manifest_repos --rows | awk -F'|' -v n="$REPO" '$1==n{print $2; exit}')"
[[ -n "$REPO_PATH" ]] || deny "repo path not found in manifest"
git -C "$REPO_PATH" rev-parse --git-dir >/dev/null 2>&1 || deny "repo path is not a git repo: $REPO_PATH"
git -C "$REPO_PATH" cat-file -e "$SHA^{commit}" 2>/dev/null || git -C "$REPO_PATH" fetch -q jeryu 2>/dev/null || true
git -C "$REPO_PATH" cat-file -e "$SHA^{commit}" 2>/dev/null || deny "sha $SHA not found in $REPO_PATH"
tele_tmp="$(mktemp -d)"; tele_wt="$tele_tmp/$REPO"
git -c filter.git-crypt.smudge=cat -c filter.git-crypt.required=false \
  -C "$REPO_PATH" worktree add -f --detach "$tele_wt" "$SHA" >/dev/null 2>&1 || deny "telemetry worktree checkout failed"
[[ -x "$tele_wt/ops/deploy/telemetry.sh" ]] || deny "missing executable ops/deploy/telemetry.sh at $SHA"

validate_telemetry(){
  local raw="$1" normalized="$2" ring="$3"
  python3 - "$raw" "$normalized" "$REPO" "$SHA" "$ring" "$TELEMETRY_MAX_AGE_SECONDS" <<'PY'
import json
import math
import sys
from datetime import datetime, timezone

raw_path, normalized_path, repo, sha, ring, max_age = sys.argv[1:7]
max_age = int(max_age)

def fail(message):
    print(message, file=sys.stderr)
    raise SystemExit(1)

try:
    with open(raw_path, "r", encoding="utf-8") as handle:
        data = json.load(handle)
except (OSError, json.JSONDecodeError) as exc:
    fail(f"telemetry JSON unreadable: {exc}")

required = [
    "schema", "source", "service", "environment", "release_sha", "sampled_at",
    "window_seconds", "samples", "error_rate", "p95_latency_ms", "crash_rate",
    "rollback_armed", "security_alerts",
]
missing = [key for key in required if key not in data]
if missing:
    fail("missing required telemetry fields: " + ",".join(missing))
if data["schema"] != "jeryu-canary-v1":
    fail(f"schema must be jeryu-canary-v1, got {data['schema']!r}")
if not str(data["service"]).strip():
    fail("service must be non-empty")
if str(data["source"]).strip().lower() == "synthetic" or not str(data["source"]).strip():
    fail("source must be real and non-synthetic")
if data["environment"] != "prod":
    fail(f"environment must be prod, got {data['environment']!r}")
if data["release_sha"] != sha:
    fail(f"release_sha mismatch: {data['release_sha']!r} != {sha}")

try:
    sampled_at = str(data["sampled_at"])
    ts = datetime.fromisoformat(sampled_at.replace("Z", "+00:00"))
    if ts.tzinfo is None:
        ts = ts.replace(tzinfo=timezone.utc)
except (TypeError, ValueError) as exc:
    fail(f"sampled_at is not RFC3339-compatible: {exc}")
age = (datetime.now(timezone.utc) - ts.astimezone(timezone.utc)).total_seconds()
if age > max_age:
    fail(f"expired telemetry: sampled_at age {age:.0f}s > {max_age}s")
if age < -120:
    fail(f"sampled_at is too far in the future: {-age:.0f}s")

def finite_float(name):
    try:
        value = float(data[name])
    except (TypeError, ValueError):
        fail(f"{name} must be numeric")
    if not math.isfinite(value):
        fail(f"{name} must be finite")
    return value

error_rate = finite_float("error_rate")
p95_latency_ms = finite_float("p95_latency_ms")
crash_rate = finite_float("crash_rate")
samples = finite_float("samples")
window_seconds = finite_float("window_seconds")
if samples <= 0:
    fail("samples must be > 0")
if window_seconds <= 0:
    fail("window_seconds must be > 0")
if error_rate < 0 or error_rate > 0.01:
    fail(f"error_rate {error_rate} exceeds budget <= 0.01")
if p95_latency_ms < 0 or p95_latency_ms > 250:
    fail(f"p95_latency_ms {p95_latency_ms} exceeds budget <= 250")
if crash_rate < 0 or crash_rate > 0.001:
    fail(f"crash_rate {crash_rate} exceeds budget <= 0.001")
if data["rollback_armed"] is not True:
    fail("rollback_armed must be true")
alerts = data.get("security_alerts") or {}
try:
    high = int(alerts.get("high"))
    critical = int(alerts.get("critical"))
except (TypeError, ValueError, AttributeError):
    fail("security_alerts.high and .critical must be integers")
if high != 0 or critical != 0:
    fail(f"security alerts must be zero (high={high}, critical={critical})")

normalized = {
    "error_rate": error_rate,
    "p95_latency_ms": int(round(p95_latency_ms)),
    "crash_rate": crash_rate,
    "sampled_at": sampled_at,
    "samples": int(samples),
}
with open(normalized_path, "w", encoding="utf-8") as handle:
    json.dump(normalized, handle, sort_keys=True)
    handle.write("\n")
print(f"telemetry OK: repo={repo} ring={ring}% source={data['source']} samples={int(samples)}")
PY
}

run_ring_telemetry(){
  local ring="$1" raw="$ev/telemetry-ring-${ring}.raw.json" normalized="$ev/telemetry-ring-${ring}.json"
  if ! ( cd "$tele_wt" && ops/deploy/telemetry.sh \
      --repo "$REPO" --sha "$SHA" --stage prod --ring-percent "$ring" --format jeryu-canary-v1 \
      >"$raw" 2>>"$log" ); then
    deny "telemetry command failed for ring ${ring}%"
  fi
  validate_telemetry "$raw" "$normalized" "$ring" >>"$log" 2>&1 || deny "telemetry validation failed for ring ${ring}%"
  printf '%s\n' "$normalized"
}

say "autonomy-deploy: $OWNER/$REPO@${SHA:0:12} — evidence gate (syft=${SYFT:-none} cosign=${COSIGN:-none})"

# --- STEP 1: FOUNDRY -> signed ReleasePassport -------------------------------------------
cat > "$ev/candidate.json" <<EOF
{"id":"${REPO}-${SHA:0:12}","commits":["$SHA"],"source_branch":"main","target_branch":"main","head_sha":"$SHA","created_at":"$(now_rfc3339)"}
EOF
fargs=(--candidate "$ev/candidate.json" --workdir "$ev")
[[ -n "$SYFT" ]] && fargs+=(--syft-bin "$SYFT"); [[ -n "$COSIGN" ]] && fargs+=(--cosign-bin "$COSIGN")
"$AUTONOMY_BIN" foundry "${fargs[@]}" > "$ev/passport.json" 2>>"$log" || deny "foundry failed"
RID="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["id"])' "$ev/passport.json" 2>/dev/null)" || deny "passport unreadable"
AD="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["artifact_digest"])' "$ev/passport.json" 2>/dev/null)" || deny "passport missing artifact_digest"
algo="$(python3 -c 'import json,sys;print((json.load(open(sys.argv[1])).get("signature") or {}).get("algo",""))' "$ev/passport.json" 2>/dev/null)"
[[ "$algo" == "ed25519" ]] || deny "passport not ed25519-signed (algo=$algo) — refusing marker-mode artifact"
say "  foundry OK: release_id=$RID digest=${AD:0:24}… signature=$algo"

# --- STEP 2: CANARY START ----------------------------------------------------------------
"$AUTONOMY_BIN" canary start --passport "$ev/passport.json" --out "$ev/canary.json" 2>>"$log" || deny "canary start failed"

# --- STEP 3: CANARY EVALUATE loop (repo-owned prod telemetry) ----------------------------
# ops/deploy/telemetry.sh is the required repo contract. The full output is persisted as
# telemetry-ring-<ring>.raw.json; a validated five-field projection is passed to the current
# autonomy canary adapter. Any missing/invalid telemetry fails closed.
POLICY="$(printf 'release-policy-v1' | sha256sum | cut -d' ' -f1)"
rings=(1 5 25 50 100)
last_kind=""; ring_idx=-1; saw_100=0; last_raw=""
for idx in "${!rings[@]}"; do
  ring="${rings[$idx]}"
  past="$(date -u -d '6 hours ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)"
  python3 - "$ev/canary.json" "$past" "$idx" <<'PY' 2>>"$log" || deny "canary state patch failed"
import json,sys
s=json.load(open(sys.argv[1]))
s["ring_entered_at"]=sys.argv[2]
s["current_ring_idx"]=int(sys.argv[3])
json.dump(s,open(sys.argv[1],"w"))
PY
  [[ "$ring" == "100" ]] && saw_100=1
  telemetry_file="$(run_ring_telemetry "$ring")"
  last_raw="$ev/telemetry-ring-${ring}.raw.json"
  dec="$("$AUTONOMY_BIN" canary evaluate --state "$ev/canary.json" --telemetry "$telemetry_file" 2>>"$log")" || deny "canary evaluate errored"
  printf '%s\n' "$dec" > "$ev/canary-decision-ring-${ring}.json"
  last_kind="$(printf '%s' "$dec" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("kind",""))' 2>/dev/null)"
  ring_idx="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("current_ring_idx",-1))' "$ev/canary.json" 2>/dev/null)"
  say "  canary ring ${ring}%: ring_idx=$ring_idx decision=$last_kind"
  [[ "$last_kind" == "rollback" ]] && deny "canary rolled back at ring_idx=$ring_idx: $dec"
done
[[ "$saw_100" == "1" ]] || deny "canary did not evaluate the 100% ring (last ring_idx=$ring_idx kind=$last_kind)"
say "  canary OK: evaluated real telemetry through the 100% ring (ring_idx=4)"

# --- STEP 4: NIGHTWATCH = the PROD gate (LLM runtime reviewer) ----------------------------
# Concise telemetry summary (long inputs can over-run the completion cap -> truncated JSON ->
# abstain). Retry on abstain/parse-miss; abstain fails closed regardless.
final_raw="$ev/telemetry-ring-100.raw.json"; [[ -f "$final_raw" ]] || final_raw="$last_raw"
nw_summary="$(python3 - "$final_raw" 2>>"$log" <<'PY'
import json
import sys

data = json.load(open(sys.argv[1]))
alerts = data.get("security_alerts") or {}
print(
    "Canary reached 100% using repo-owned prod telemetry. "
    f"schema={data.get('schema')}; source={data.get('source')}; service={data.get('service')}; "
    f"environment={data.get('environment')}; release_sha={data.get('release_sha')}; "
    f"samples={data.get('samples')} over window_seconds={data.get('window_seconds')}; "
    f"error_rate={data.get('error_rate')} (budget 0.01); "
    f"p95_latency_ms={data.get('p95_latency_ms')} (budget 250); "
    f"crash_rate={data.get('crash_rate')} (budget 0.001); "
    f"rollback_armed={data.get('rollback_armed')}; "
    f"security_alerts.high={alerts.get('high')}; security_alerts.critical={alerts.get('critical')}."
)
PY
)" || deny "nightwatch telemetry summary failed"
decision=""; reason=""
for try in $(seq 1 "$NIGHTWATCH_RETRIES"); do
  printf '%s' "$nw_summary" | "$AUTONOMY_BIN" nightwatch --autonomy-dir "$AUTONOMY_DIR" \
    --release-id "$RID" --artifact-digest "$AD" --head-sha "$SHA" --policy-sha "$POLICY" \
    --ring-percent 100 > "$ev/nightwatch-receipt.json" 2>>"$log" || true
  decision="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("decision",""))' "$ev/nightwatch-receipt.json" 2>/dev/null)"
  reason="$(python3 -c 'import json,sys;print((json.load(open(sys.argv[1])).get("reason") or "")[:140])' "$ev/nightwatch-receipt.json" 2>/dev/null)"
  say "  nightwatch try $try: decision=$decision"
  [[ "$decision" == "pass" || "$decision" == "block" || "$decision" == "concern" ]] && break
done

if [[ "$decision" == "pass" ]]; then
  python3 - "$ev/decision.json" "$SHA" "$RID" "$AD" "$reason" "$final_raw" <<'PY' 2>/dev/null || true
import json,sys; json.dump(dict(sha=sys.argv[2],release_id=sys.argv[3],artifact_digest=sys.argv[4],
  prod_granted=True,outcome="promote",gate="nightwatch",decision="pass",reason=sys.argv[5],
  telemetry_evidence=sys.argv[6]),open(sys.argv[1],"w"),indent=1)
PY
  ok "PROD GRANTED $OWNER/$REPO@${SHA:0:12} — canary→nightwatch pass; evidence: $ev"
  post_check "$OWNER" "$REPO" "$SHA" "jeryu/promote" success
  echo promote; exit 0
fi
deny "nightwatch did not pass (decision='${decision:-none}': ${reason:-})"
