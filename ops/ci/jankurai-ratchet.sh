#!/usr/bin/env bash
# Jankurai regression ratchet.
#
# Runs `jankurai audit` and FAILS (exit 1) if the result regresses versus the
# accepted baseline at agent/repo-score-baseline.json: a lower final score, a
# newly-applied cap, or more total findings. This makes it impossible to
# commit/push (via ops/git-hooks) — and, when wired into CI, to merge —
# anything that worsens the repository's jankurai conformance.
#
# The baseline is a compact summary ({score, raw_score, caps_applied,
# rule_counts}) shared with the CI audit lane. It only ratchets UP via
# `ops/ci/jankurai-ratchet.sh --accept`, run after a clean, improved audit.
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

BASELINE="${JANKURAI_BASELINE:-agent/repo-score-baseline.json}"
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

# Write/refresh the compact baseline summary from a full audit report.
write_summary() {
  python3 - "$1" "$2" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
sc = d.get("score")
if isinstance(sc, dict):
    sc = sc.get("final") or sc.get("value")
if not isinstance(sc, (int, float)):
    sc = d.get("raw_score", 0)
counts = {}
for f in (d.get("findings") or []):
    r = f.get("rule") or f.get("rule_id") or "unknown"
    counts[r] = counts.get(r, 0) + 1
out = {
    "score": sc,
    "raw_score": d.get("raw_score"),
    "caps_applied": d.get("caps_applied") or [],
    "rule_counts": dict(sorted(counts.items())),
}
json.dump(out, open(sys.argv[2], "w"), indent=2)
open(sys.argv[2], "a").write("\n")
PY
}

if [[ "$ACCEPT" == "1" ]]; then
  write_summary "$CUR" "$BASELINE"
  echo "[ratchet] baseline accepted from current audit -> $BASELINE"
  exit 0
fi

if [[ ! -f "$BASELINE" ]]; then
  echo "[ratchet] no baseline ($BASELINE); seeding from current audit" >&2
  write_summary "$CUR" "$BASELINE"
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
    # Total findings: a summary baseline carries rule_counts; a full audit
    # report carries a findings[] array (or decision counts). Compare totals so
    # both formats line up.
    rc = d.get("rule_counts")
    if isinstance(rc, dict) and rc:
        findings = sum(int(v) for v in rc.values())
    elif d.get("findings") is not None:
        findings = len(d["findings"])
    else:
        dec = d.get("decision") or {}
        findings = int(dec.get("finding_count")
                       or (dec.get("hard_findings") or 0) + (dec.get("soft_findings") or 0))
    return float(sc), caps, int(findings)

bs, bc, bf = fields(sys.argv[1])
cs, cc, cf = fields(sys.argv[2])
print(f"[ratchet] baseline: score={bs:g} caps={len(bc)} findings={bf}  |  "
      f"current: score={cs:g} caps={len(cc)} findings={cf}")
regress = []
if cs < bs:
    regress.append(f"score dropped {bs:g} -> {cs:g}")
new_caps = sorted(cc - bc)
if new_caps:
    regress.append(f"new cap(s): {', '.join(new_caps)}")
if cf > bf:
    regress.append(f"findings rose {bf} -> {cf}")
if regress:
    sys.stderr.write("[ratchet] REGRESSION — rejected:\n")
    for r in regress:
        sys.stderr.write(f"   - {r}\n")
    sys.stderr.write("[ratchet] fix it, or run `ops/ci/jankurai-ratchet.sh --accept` "
                     "only if the audit IMPROVED.\n")
    sys.exit(1)
print("[ratchet] OK — no jankurai regression")
PY
