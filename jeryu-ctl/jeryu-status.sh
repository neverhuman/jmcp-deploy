#!/usr/bin/env bash
# jeryu-ctl/jeryu-status.sh — READ-ONLY fleet dashboard for the jeryu control plane.
#
# For each repo in repos.manifest.toml (--rows) it prints one row:
#   name | jeryu main sha | open jeryu PR count | jeryu/ci | jeryu/agent-review
#        | jeryu/release | jeryu/promote | SignRail receipts | telemetry evidence
#        | local merge gate
# All checks are read from the running jeryu-api server (via lib.sh helpers) and
# local jeryu bare repos. This script NEVER mutates anything — no pushes, no
# check-runs, no merges, no PR creation, and no GitHub Actions queries. Pure observation.
#
# usage: jeryu-status.sh [--max-wave N]   (default: all manifest rows)
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; . "$HERE/lib.sh"; . "$HERE/manifest.sh"

MAXWAVE=""
while [[ $# -gt 0 ]]; do case "$1" in
  --max-wave) shift; MAXWAVE="${1:-}";;
  *) die "unknown arg: $1";;
esac; shift; done

# Colorize a check conclusion for the terminal.
fmt() {
  local v="$1"
  case "$v" in
    success)               printf '%ssuccess%s' "$c_grn" "$c_off" ;;
    clear|ready)           printf '%s%s%s' "$c_grn" "$v" "$c_off" ;;
    failure|cancelled|timed_out|action_required|startup_failure)
                           printf '%s%s%s' "$c_red" "$v" "$c_off" ;;
    "")                    printf '%s—%s' "$c_ylw" "$c_off" ;;
    *)                     printf '%s%s%s' "$c_ylw" "$v" "$c_off" ;;
  esac
}

# Count open PRs into main on jeryu for owner/repo (client-side state filter —
# the jeryu pulls endpoint returns ALL records regardless of ?state=).
jeryu_open_pr_count() {
  local owner="$1" repo="$2"
  curl -fsS --max-time 10 "$JERYU_BASE/repos/$owner/$repo/pulls?state=open" 2>/dev/null | python3 -c '
import sys, json
try: d = json.load(sys.stdin)
except Exception: print(0); sys.exit(0)
arr = d if isinstance(d, list) else d.get("items", [])
n = sum(1 for p in arr
        if p.get("state") == "open" and not p.get("draft")
        and (p.get("base") or {}).get("ref") == "main")
print(n)
'
}

local_merge_gate() {
  local owner="$1" repo="$2" bare="$3"
  local pulls
  pulls="$(curl -fsS --max-time 10 "$JERYU_BASE/repos/$owner/$repo/pulls?state=open" 2>/dev/null)" || {
    printf '%s' unknown
    return
  }
  python3 - "$owner" "$repo" "$bare" "$HERE/lib.sh" "$pulls" <<'PY'
import json
import subprocess
import sys

owner, repo, bare, lib, pulls_json = sys.argv[1:6]
try:
    pulls = json.loads(pulls_json)
except Exception:
    print("unknown")
    raise SystemExit

items = pulls if isinstance(pulls, list) else pulls.get("items", [])
blocked = []
ready = 0
for p in items:
    if p.get("state") != "open" or p.get("draft"):
        continue
    if (p.get("base") or {}).get("ref") != "main":
        continue
    labels = [l.get("name", "") if isinstance(l, dict) else str(l) for l in (p.get("labels") or [])]
    if any(x in ("hold", "do-not-merge", "wip") for x in labels):
        continue
    head = (p.get("head") or {}).get("ref")
    if not head:
        continue
    try:
        sha = subprocess.check_output(
            ["git", "-C", bare, "rev-parse", "--verify", f"refs/heads/{head}"],
            stderr=subprocess.DEVNULL,
            text=True,
        ).strip()
    except subprocess.CalledProcessError:
        blocked.append(f"#{p.get('number')} missing-head")
        continue

    def check(name):
        try:
            return subprocess.check_output(
                ["/bin/bash", "-c", '. "$1"; check_conclusion "$2" "$3" "$4" "$5"', "bash", lib, owner, repo, sha, name],
                stderr=subprocess.DEVNULL,
                text=True,
            ).strip()
        except subprocess.CalledProcessError:
            return ""

    if check("jeryu/merge") in {"failure", "cancelled", "timed_out", "action_required", "startup_failure"}:
        blocked.append(f"#{p.get('number')} merge-failed")
        continue

    if check("jeryu/ci") == "success" and check("jeryu/agent-review") == "success":
        ready += 1
        if subprocess.run(
            ["git", "-C", bare, "merge-base", "--is-ancestor", "refs/heads/main", sha],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        ).returncode != 0:
            blocked.append(f"#{p.get('number')} non-ff")

if blocked:
    print(",".join(blocked))
elif ready:
    print("ready")
else:
    print("clear")
PY
}

signrail_receipts_gate() {
  local github_slug="$1" sha="$2" root="${SIGNRAIL_STORE_ROOT:-/home/ubuntu/.local/share/jeryu/signrail}"
  python3 - "$root" "$github_slug" "$sha" <<'PY'
import json
import pathlib
import sys

root, slug, sha = sys.argv[1:4]
key = slug.replace("/", "_")
missing = []
bad = []
for stage in ("local", "dev-canary", "prod"):
    path = pathlib.Path(root) / "receipts" / f"{key}@{sha}-{stage}.json"
    if not path.is_file():
        missing.append(stage)
        continue
    try:
        data = json.loads(path.read_text())
    except Exception:
        bad.append(f"{stage}:json")
        continue
    payload = data.get("payload") or {}
    if payload.get("stage") != stage:
        bad.append(f"{stage}:stage")
    if payload.get("sha") != sha:
        bad.append(f"{stage}:sha")
    if payload.get("signature_coverage_percent") != 100:
        bad.append(f"{stage}:coverage")
if missing:
    print("missing:" + ",".join(missing))
elif bad:
    print("bad:" + ",".join(bad))
else:
    print("success")
PY
}

telemetry_evidence_gate() {
  local owner="$1" repo="$2" sha="$3" root="${DEPLOY_EVIDENCE_ROOT:-/home/ubuntu/.local/share/jeryu/deploy-evidence}"
  python3 - "$root" "$owner" "$repo" "$sha" <<'PY'
import json
import pathlib
import sys

root, owner, repo, sha = sys.argv[1:5]
base = pathlib.Path(root) / f"{owner}__{repo}" / sha
missing = []
bad = []
for ring in (1, 5, 25, 50, 100):
    path = base / f"telemetry-ring-{ring}.raw.json"
    if not path.is_file():
        missing.append(str(ring))
        continue
    try:
        data = json.loads(path.read_text())
    except Exception:
        bad.append(f"{ring}:json")
        continue
    if data.get("schema") != "jeryu-canary-v1":
        bad.append(f"{ring}:schema")
    if str(data.get("source", "")).strip().lower() == "synthetic" or not str(data.get("source", "")).strip():
        bad.append(f"{ring}:source")
    if data.get("environment") != "prod":
        bad.append(f"{ring}:env")
    if data.get("release_sha") != sha:
        bad.append(f"{ring}:sha")
    try:
        samples = float(data.get("samples"))
    except Exception:
        samples = 0
    if samples <= 0:
        bad.append(f"{ring}:samples")
    if data.get("rollback_armed") is not True:
        bad.append(f"{ring}:rollback")
    alerts = data.get("security_alerts") or {}
    try:
        high = int(alerts.get("high"))
        critical = int(alerts.get("critical"))
    except Exception:
        high = critical = -1
    if high != 0 or critical != 0:
        bad.append(f"{ring}:alerts")
if missing:
    print("missing:" + ",".join(missing))
elif bad:
    print("bad:" + ",".join(bad[:4]))
else:
    print("success")
PY
}

j_health || warn "jeryu server not healthy at $JERYU_BASE — jeryu columns may be blank"

hdr_name="REPO"; hdr_sha="JERYU-MAIN"; hdr_pr="PR"
hdr_ci="jeryu/ci"; hdr_rev="agent-review"; hdr_rel="release"; hdr_prom="promote"
hdr_receipts="receipts"; hdr_tel="telemetry"; hdr_merge="merge"
printf '%s%-22s %-13s %-3s %-9s %-13s %-9s %-9s %-14s %-14s %-16s%s\n' \
  "$c_cyn" "$hdr_name" "$hdr_sha" "$hdr_pr" "$hdr_ci" "$hdr_rev" "$hdr_rel" "$hdr_prom" "$hdr_receipts" "$hdr_tel" "$hdr_merge" "$c_off"
printf '%s%s%s\n' "$c_cyn" "$(printf '%.0s-' {1..128})" "$c_off"

all_green=1; rows=0
manifest_args=(--rows); [[ -n "$MAXWAVE" ]] && manifest_args=(--max-wave "$MAXWAVE" --rows)

while IFS='|' read -r name path slug jslug; do
  [[ -n "$jslug" ]] || continue
  rows=$((rows+1))
  owner="${jslug%%/*}"; repo="${jslug#*/}"
  bare="$(bare_path "$owner" "$repo")"

  # jeryu main sha via smart-HTTP git server (read-only ls-remote).
  sha="$(git ls-remote "$JERYU_BASE/git/$jslug.git" refs/heads/main 2>/dev/null | awk 'NR==1{print $1}')"
  short="${sha:0:12}"; [[ -z "$short" ]] && short="-"

  prc="$(jeryu_open_pr_count "$owner" "$repo")"; [[ -z "$prc" ]] && prc="?"

  ci="" rev="" rel="" prom="" receipts="" telemetry=""
  if [[ -n "$sha" ]]; then
    ci="$(check_conclusion "$owner" "$repo" "$sha" jeryu/ci)"
    rev="$(check_conclusion "$owner" "$repo" "$sha" jeryu/agent-review)"
    rel="$(check_conclusion "$owner" "$repo" "$sha" jeryu/release)"
    prom="$(check_conclusion "$owner" "$repo" "$sha" jeryu/promote)"
    receipts="$(signrail_receipts_gate "$slug" "$sha")"
    telemetry="$(telemetry_evidence_gate "$owner" "$repo" "$sha")"
  fi
  merge_gate="unknown"
  [[ -d "$bare" ]] && merge_gate="$(local_merge_gate "$owner" "$repo" "$bare")"

  # Fleet health is local-Jeryu only. Current main must have all required local
  # checks, and there must be no ready-but-unmergeable local PR.
  for v in "$ci" "$rev" "$rel" "$prom" "$receipts" "$telemetry"; do
    [[ "$v" == "success" ]] || all_green=0
  done
  case "$merge_gate" in clear|ready) ;; *) all_green=0;; esac

  printf '%-22s %-13s %-3s %b %b %b %b %b %b %b\n' \
    "$name" "$short" "$prc" \
    "$(printf '%-9s' "$(fmt "$ci")")" \
    "$(printf '%-13s' "$(fmt "$rev")")" \
    "$(printf '%-9s' "$(fmt "$rel")")" \
    "$(printf '%-9s' "$(fmt "$prom")")" \
    "$(printf '%-14s' "$(fmt "$receipts")")" \
    "$(printf '%-14s' "$(fmt "$telemetry")")" \
    "$(printf '%-16s' "$(fmt "$merge_gate")")"
done < <(manifest_repos "${manifest_args[@]}")

printf '%s%s%s\n' "$c_cyn" "$(printf '%.0s-' {1..128})" "$c_off"
if [[ "$all_green" == "1" ]]; then
  printf '%sSUMMARY: GREEN — all %d repos satisfy local Jeryu gates (ci, agent-review, release, promote, receipts, telemetry; no merge failures)%s\n' \
    "$c_grn" "$rows" "$c_off"
else
  printf '%sSUMMARY: RED — at least one local Jeryu gate or merge check failed across %d repos%s\n' \
    "$c_red" "$rows" "$c_off"
fi
