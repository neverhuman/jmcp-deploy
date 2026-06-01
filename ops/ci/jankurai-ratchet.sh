#!/usr/bin/env bash
# Jankurai regression ratchet.
#
# Runs `jankurai audit` and FAILS (exit 1) if the result regresses versus the
# accepted baseline at agent/baselines/main.repo-score.json: a lower final
# score, a newly-applied cap, or more hard findings. This makes it impossible
# to commit/push (and, via the CI job, to merge) anything that worsens the
# repository's jankurai conformance. The baseline only ever ratchets UP via
# `ops/ci/jankurai-ratchet.sh --accept` after a clean, improved audit.
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

BASELINE="agent/baselines/main.repo-score.json"
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
"$JANKURAI" audit . --mode "$MODE" --json "$CUR" --md "$WORK/repo-score.md" >/dev/null 2>&1 \
  || { echo "[ratchet] jankurai audit failed to run" >&2; exit 1; }

if [[ "$ACCEPT" == "1" ]]; then
  cp "$CUR" "$BASELINE"
  echo "[ratchet] baseline accepted from current audit -> $BASELINE"
  exit 0
fi

if [[ ! -f "$BASELINE" ]]; then
  echo "[ratchet] no baseline ($BASELINE); seeding from current audit" >&2
  cp "$CUR" "$BASELINE"
  exit 0
fi

python3 - "$BASELINE" "$CUR" <<'PY'
import json, sys
def fields(p):
    d = json.load(open(p))
    sc = d.get("score")
    if isinstance(sc, dict):
        sc = sc.get("final") or sc.get("value")
    if not isinstance(sc, (int, float)):
        sc = d.get("raw_score", 0)
    caps = set(d.get("caps_applied") or [])
    dec = d.get("decision") or {}
    hard = dec.get("hard_findings")
    if hard is None:
        hard = sum(1 for f in (d.get("findings") or []) if f.get("severity") == "high")
    return float(sc), caps, int(hard)

bs, bc, bh = fields(sys.argv[1])
cs, cc, ch = fields(sys.argv[2])
print(f"[ratchet] baseline: score={bs:g} caps={len(bc)} hard={bh}  |  current: score={cs:g} caps={len(cc)} hard={ch}")
regress = []
if cs < bs:
    regress.append(f"score dropped {bs:g} -> {cs:g}")
new_caps = sorted(cc - bc)
if new_caps:
    regress.append(f"new cap(s): {', '.join(new_caps)}")
if ch > bh:
    regress.append(f"hard findings rose {bh} -> {ch}")
if regress:
    sys.stderr.write("[ratchet] REGRESSION — rejected:\n")
    for r in regress:
        sys.stderr.write(f"   - {r}\n")
    sys.stderr.write("[ratchet] fix the regression, or run `ops/ci/jankurai-ratchet.sh --accept` only if the score IMPROVED.\n")
    sys.exit(1)
print("[ratchet] OK — no jankurai regression")
PY
