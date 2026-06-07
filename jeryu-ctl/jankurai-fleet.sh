#!/usr/bin/env bash
# jeryu-ctl/jankurai-fleet.sh — SYSTEM-WIDE jankurai audit aggregator (Cluster 4.1).
#
# Produces ~/.jankurai/fleet-board.json (the EXACT FleetBoardPayload that JMCP /fleet-board already
# reads — routes_extra.rs), giving one view of which repos fail jankurai + their scores. Manifest-
# driven (like jeryu-status.sh). Prefers each repo's cached .jankurai/repo-score.json; with --mode
# full it runs `jankurai score` for uncached repos into a TEMP --json path so it NEVER mutates a repo
# (no generated-zone-mutation-risk, no dirtied tree). Writes ONLY under ~/.jankurai/ + $TMPDIR.
#
# usage: jankurai-fleet.sh [--mode cached|full] [--max-wave N] [--repo R] [--print]
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; . "$HERE/lib.sh"; . "$HERE/manifest.sh"
STORE="${SIGNRAIL_STORE_ROOT:-/home/ubuntu/.local/share/jeryu/signrail}"
OUT="${JANKURAI_FLEET_JSON:-/home/ubuntu/.jankurai/fleet-board.json}"
OUT_MD="${JANKURAI_FLEET_MD:-/home/ubuntu/.jankurai/fleet-board.md}"
mode="cached"; max_wave=2; only=""; do_print=0
while [[ $# -gt 0 ]]; do case "$1" in
  --mode) shift; mode="${1:-cached}";; --max-wave) shift; max_wave="${1:-2}";; --repo) shift; only="${1:-}";; --print) do_print=1;; *) warn "unknown $1";; esac; shift; done

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
manifest_repos --rows 2>/dev/null > "$tmp/rows"
JANKURAI_BIN="$(command -v jankurai || echo jankurai)"

python3 - "$JERYU_BASE" "$JERYU_GIT_ROOT" "$STORE" "$tmp/rows" "$mode" "$only" "$JANKURAI_BIN" "$tmp" > "$tmp/payload.json" <<'PY'
import sys, os, json, glob, subprocess, time, re
BASE,GITROOT,STORE,ROWS,MODE,ONLY,JBIN,TMP = sys.argv[1:9]
def git(p,*a):
    try: return subprocess.run(["git","-C",p,*a],capture_output=True,text=True,timeout=12).stdout.strip()
    except (OSError, subprocess.SubprocessError): return ""
def load(p):
    try: return json.load(open(p))
    except (OSError, json.JSONDecodeError): return None
now=int(time.time())
repos=[]; errors=[]
for line in open(ROWS):
    line=line.strip()
    if not line: continue
    name,path,gslug,jslug=(line.split("|")+["","","",""])[:4]
    if not name or not path: continue
    if ONLY and ONLY!=name: continue
    owner,repo=(jslug.split("/",1)+[""])[:2] if jslug else ("jeryu",name)
    head=git(path,"rev-parse","HEAD") or None
    dirty=len([l for l in git(path,"status","--porcelain").splitlines() if l.strip()])
    branch=git(path,"rev-parse","--abbrev-ref","HEAD") or "main"
    commit_when=git(path,"log","-1","--format=%cI") or None
    commit_epoch=git(path,"log","-1","--format=%ct"); commit_epoch=int(commit_epoch) if commit_epoch.isdigit() else None
    ci_configured=os.path.isdir(os.path.join(path,".github","workflows"))
    # --- jankurai score: cached, else (full) run into a TEMP json (never inside the repo) ---
    sj=os.path.join(path,".jankurai","repo-score.json")
    score=None; src=None; fresh="unaudited"
    sd=load(sj) if os.path.isfile(sj) else None
    if sd:
        src="cached"
        embedded=((sd.get("git") or {}).get("commit") or (sd.get("git") or {}).get("head_sha") or "")
        fresh = "fresh" if (dirty==0 and head and embedded and head.startswith(embedded[:12])) else "cached"
    elif MODE=="full":
        outj=os.path.join(TMP, f"{name}.score.json")
        try:
            r=subprocess.run([JBIN,"score",path,"--json",outj,"--md","/dev/null","--mode","standard"],
                             capture_output=True,text=True,timeout=240)
            sd=load(outj)
            if sd: src="fresh"; fresh="fresh"
            else: errors.append({"repo":name,"message":(r.stderr or "score produced no json")[:200]})
        except subprocess.TimeoutExpired:
            errors.append({"repo":name,"message":"jankurai score timed out (240s)"})
        except (OSError, subprocess.SubprocessError) as e:
            errors.append({"repo":name,"message":str(e)[:200]})
    dec=(sd or {}).get("decision") or {}
    score=(sd or {}).get("score"); raw=(sd or {}).get("raw_score")
    caps=[c.get("id") if isinstance(c,dict) else str(c) for c in ((sd or {}).get("caps_applied") or [])]
    hard=dec.get("hard_findings")
    hl=(sd or {}).get("observed_conformance_level")
    findings=[ (f.get("title") or f.get("id") or "") for f in ((sd or {}).get("findings") or []) ][:5]
    ta=(sd or {}).get("tool_adoption") or {}
    tops=[ (m if isinstance(m,str) else (m.get("tool") or m.get("id") or "")) for m in (ta.get("missing") or []) ][:5]
    # version (signrail .version sidecar / release.json / Cargo.toml)
    key=(gslug or jslug).replace("/","_")
    version=None
    rels=sorted(glob.glob(f"{STORE}/releases/{key}@*.json"), key=os.path.getmtime, reverse=True)
    latest_sha=None
    if rels:
        d=load(rels[0]) or {}; version=d.get("version"); latest_sha=(d.get("commit_sha") or "")[:12]
    if not version:
        m=re.search(r'\[workspace\.package\][^\[]*?version\s*=\s*"([^"]+)"', git(path,"show","HEAD:Cargo.toml"), re.S)
        if m: version=m.group(1)
    # artifact_state from signrail receipts of the latest signed sha
    def stage_state(stg):
        bsha=(load(rels[0]) or {}).get("commit_sha","") if rels else ""
        return "signed" if (bsha and os.path.isfile(f"{STORE}/receipts/{key}@{bsha}-{stg}.json")) else "missing"
    art={"local":stage_state("local"),"dev_canary":stage_state("dev-canary"),"prod":stage_state("prod"),
         "release":"signed" if rels else "missing","promote":stage_state("prod"),"latest_sha":latest_sha}
    gate = "fail" if (score is not None and isinstance(score,int) and score<85) or (hard or 0)>0 else ("pass" if score is not None else "unknown")
    repos.append({"name":name,"path":path,"branch":branch,"host":"jeryu" if jslug else "github",
        "dirty":dirty,"dirty_files":dirty,"last_commit_sha":head,"head_sha":head,
        "last_commit_when":commit_when,"last_commit_epoch":commit_epoch,
        "last_binary_epoch":int(os.path.getmtime(rels[0])) if rels else None,"last_tests_epoch":None,
        "version":version,"ci_configured":ci_configured,
        "score":score,"raw":raw,"caps":caps,"caps_count":len(caps),"hard_findings":hard,
        "hl_level":hl,"score_source":src,"score_freshness":fresh,
        "active_runner_count":0,"runner_busy":False,"runner_hint":None,"main_ci_age_seconds":None,
        "jeryu_gate":gate,"artifact_state":art,"top_findings":findings,"top_tool_opportunities":tops})
scored=[r for r in repos if isinstance(r["score"],int)]
totals={"repo_count":len(repos),"audited":len(scored),
        "failed":sum(1 for r in scored if r["jeryu_gate"]=="fail"),
        "min_score":min((r["score"] for r in scored),default=None),
        "max_score":max((r["score"] for r in scored),default=None),
        "average_score":round(sum(r["score"] for r in scored)/len(scored),1) if scored else None,
        "total_hard_findings":sum((r["hard_findings"] or 0) for r in repos),
        "below_threshold":sum(1 for r in scored if r["score"]<85)}
repos.sort(key=lambda r:(0 if r["jeryu_gate"]=="fail" else 1 if r["score"] is None else 2, r["name"]))
print(json.dumps({"generated_at_note":f"jankurai-fleet.sh mode={MODE} at epoch {now}",
    "schema":"jankurai.fleet.v1","repos":repos,"totals":totals,"errors":errors}))
PY

[[ -s "$tmp/payload.json" ]] || die "jankurai-fleet: produced no payload"
if [[ "$do_print" == "1" ]]; then
  python3 - "$tmp/payload.json" <<'PY'
import sys,json
d=json.load(open(sys.argv[1])); t=d["totals"]
print(f'JANKURAI FLEET  {t["repo_count"]} repos  audited={t["audited"]} failed={t["failed"]} avg={t["average_score"]} below85={t["below_threshold"]}')
print(f'{"REPO":22}{"SCORE":7}{"HARD":6}{"CAPS":6}{"GATE":8}FRESHNESS')
for r in d["repos"]:
    print(f'{r["name"]:22}{str(r["score"]):7}{str(r["hard_findings"] or 0):6}{str(r["caps_count"]):6}{r["jeryu_gate"]:8}{r["score_freshness"]}')
if d["errors"]: print("errors:", [(e["repo"],e["message"][:40]) for e in d["errors"]])
PY
fi
mkdir -p "$(dirname "$OUT")"; cp "$tmp/payload.json" "$OUT"; ok "jankurai-fleet: wrote $OUT (mode=$mode)"
