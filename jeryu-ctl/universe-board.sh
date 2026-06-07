#!/usr/bin/env bash
# jeryu-ctl/universe-board.sh — the mission-control "UNIVERSE" page (Cluster 1B).
#
# One view of EVERY manifest repo: main sha, time-since-last-successful jeryu/ci, open PRs, current
# version, last signed binary (+ stages), live runner activity, health. PURE read-only aggregation
# (local jeryu :8787 + signrail store + git + the policer cache). No builds, no audits, no mutations.
# Emits JSON (~/.jeryu/universe-board.json) as a FleetBoard-compatible operational projection
# for the JMCP cockpit model, plus a zero-dependency auto-refresh HTML page. Jankurai remains
# the source of score/caps/hard-finding truth; this producer only fills repo identity, gate,
# CI, artifact, runner, version, and finding hints.
#
# usage: universe-board.sh [--json] [--html] [--print] [--max-wave N]   (default --print)
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; . "$HERE/lib.sh"; . "$HERE/manifest.sh"
STORE="${SIGNRAIL_STORE_ROOT:-/home/ubuntu/.local/share/jeryu/signrail}"
OUT_JSON="${UNIVERSE_JSON:-/home/ubuntu/.jeryu/universe-board.json}"
OUT_HTML="${UNIVERSE_HTML:-/home/ubuntu/.jeryu/universe-board.html}"
POBS="${PROCESS_OBS_CACHE:-/home/ubuntu/.jeryu/process-observations.json}"
do_json=0; do_html=0; do_print=0; max_wave=2
while [[ $# -gt 0 ]]; do case "$1" in
  --json) do_json=1;; --html) do_html=1;; --print) do_print=1;; --max-wave) shift; max_wave="${1:-2}";; *) warn "unknown $1";; esac; shift; done
[[ "$do_json$do_html$do_print" == "000" ]] && do_print=1

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
manifest_repos --rows 2>/dev/null > "$tmp/rows"

# --- aggregate (rows via FILE arg; stdin is the heredoc script) ---
python3 - "$JERYU_BASE" "$JERYU_GIT_ROOT" "$STORE" "$POBS" "$tmp/rows" > "$tmp/data.json" <<'PY'
import sys, os, json, glob, subprocess, time, re, urllib.error, urllib.request, datetime
BASE, GITROOT, STORE, POBS, ROWS = sys.argv[1:6]
def git(repo,*a):
    try: return subprocess.run(["git","-C",repo,*a],capture_output=True,text=True,timeout=10).stdout.strip()
    except (OSError, subprocess.SubprocessError): return ""
def api(path):
    try:
        with urllib.request.urlopen(f"{BASE}{path}", timeout=8) as r: return json.load(r)
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError): return None
def check_runs_all(owner,repo,sha):
    # the jeryu endpoint returns ALL the repo's check-runs UNFILTERED by sha — must paginate.
    items=[]; page=1
    while page<=25:
        d=api(f"/repos/{owner}/{repo}/commits/{sha}/check-runs?per_page=100&page={page}")
        if not d: break
        pi=d.get("check_runs") if isinstance(d,dict) else d
        if not pi: break
        items.extend(pi)
        if len(pi)<100: break
        page+=1
    return items
def parse_ts(s):
    if not s: return None
    s=s.rstrip("Z")
    if "." in s: h,fr=s.split(".",1); s=h+"."+fr[:6]
    try: return datetime.datetime.fromisoformat(s).replace(tzinfo=datetime.timezone.utc).timestamp()
    except ValueError: return None
now=time.time()
pobs={}
if os.path.isfile(POBS):
    try:
        j=json.load(open(POBS)); j=j if isinstance(j,list) else j.get("observations",[])
        for o in j: pobs[o.get("process_key","")]=o
    except (OSError, json.JSONDecodeError, TypeError): pass
rows=[]
for line in open(ROWS):
    line=line.strip()
    if not line: continue
    name,path,gslug,jslug=(line.split("|")+["","","",""])[:4]
    if not jslug: continue
    owner,repo=jslug.split("/",1); bare=f"{GITROOT}/{owner}/{repo}.git"
    main=git(bare,"rev-parse","refs/heads/main")
    head=main or git(path,"rev-parse","HEAD")
    branch=git(path,"rev-parse","--abbrev-ref","HEAD") or "main"
    dirty=len([l for l in git(path,"status","--porcelain").splitlines() if l.strip()]) if path else None
    last_commit_when=git(bare,"show","-s","--format=%cI",main) if main else None
    last_commit_epoch=git(bare,"show","-s","--format=%ct",main) if main else ""
    last_commit_epoch=int(last_commit_epoch) if str(last_commit_epoch).isdigit() else None
    runs=[r for r in check_runs_all(owner,repo,main) if r.get("head_sha")==main]
    runs.sort(key=lambda r:(r.get("completed_at") or r.get("started_at") or ""))
    latest={r.get("name"):r for r in runs}
    gates={n:(latest.get(f"jeryu/{n}") or {}).get("conclusion","") for n in ("ci","agent-review","release","promote")}
    ci=latest.get("jeryu/ci") or {}
    cit=parse_ts(ci.get("completed_at")) if ci.get("conclusion")=="success" else None
    secs=int(now-cit) if cit else None
    key=gslug.replace("/","_")
    rels=sorted(glob.glob(f"{STORE}/releases/{key}@*.json"), key=os.path.getmtime, reverse=True)
    last_bin=None; version=None
    if rels:
        try:
            d=json.load(open(rels[0])); bsha=d.get("commit_sha","")
            stages=[s for s in ("local","dev-canary","prod") if os.path.isfile(f"{STORE}/receipts/{key}@{bsha}-{s}.json")]
            last_bin={"sha":bsha[:12],"version":d.get("version",""),"stages":stages,"epoch":int(os.path.getmtime(rels[0]))}
            version=d.get("version")
        except (OSError, json.JSONDecodeError, TypeError): pass
    if not version:
        sc=sorted(glob.glob(f"{STORE}/releases/{key}@*.version"), key=os.path.getmtime, reverse=True)
        if sc:
            try: version=open(sc[0]).read().strip()
            except OSError: pass
    if not version and main:
        m=re.search(r'\[workspace\.package\][^\[]*?version\s*=\s*"([^"]+)"', git(bare,"show",f"{main}:Cargo.toml"), re.S)
        if m: version=m.group(1)
    ra=pobs.get(f"{owner}__{repo}") or pobs.get(repo) or {}
    g=[gates[n] for n in ("ci","agent-review","release","promote")]
    if all(x=="success" for x in g): jeryu_gate="pass"
    elif any(x=="failure" for x in g): jeryu_gate="fail"
    elif main and any(g): jeryu_gate="pending"
    else: jeryu_gate="unknown"
    stages=(last_bin or {}).get("stages",[])
    prod_signed="signed" if "prod" in stages else "missing"
    artifact_state={
        "local":"signed" if "local" in stages else "missing",
        "dev_canary":"signed" if "dev-canary" in stages else "missing",
        "prod":prod_signed,
        "release":"signed" if last_bin else "missing",
        "promote":prod_signed,
        "latest_sha":(last_bin or {}).get("sha"),
    }
    runner_status=ra.get("status")
    runner_busy=runner_status in ("running","stuck","errored","failed")
    findings=[]
    for gate,status in gates.items():
        if status=="failure":
            findings.append(f"jeryu/{gate} failure")
    if jeryu_gate in ("pending","unknown"):
        findings.append(f"jeryu gate {jeryu_gate}")
    if runner_status in ("stuck","errored","failed"):
        findings.append(f"runner {runner_status}")
    opportunities=[]
    if not last_bin:
        opportunities.append("signed artifact not observed")
    if secs is None:
        opportunities.append("successful main CI not observed")
    rows.append({
        "name":repo,
        "path":path,
        "branch":branch,
        "host":"jeryu",
        "dirty":dirty,
        "dirty_files":dirty,
        "last_commit_sha":head,
        "head_sha":head,
        "last_commit_when":last_commit_when,
        "last_commit_epoch":last_commit_epoch,
        "last_binary_epoch":(last_bin or {}).get("epoch"),
        "last_tests_epoch":int(cit) if cit else None,
        "version":version,
        "ci_configured":bool(runs or os.path.isdir(os.path.join(path,".github","workflows"))),
        "score":None,
        "raw":None,
        "caps":[],
        "caps_count":None,
        "hard_findings":None,
        "hl_level":None,
        "score_source":None,
        "score_freshness":"unscored",
        "active_runner_count":1 if runner_busy else 0,
        "runner_busy":runner_busy,
        "runner_hint":f"process observation: {runner_status}" if runner_status else None,
        "main_ci_age_seconds":secs,
        "jeryu_gate":jeryu_gate,
        "artifact_state":artifact_state,
        "top_findings":findings[:5],
        "top_tool_opportunities":opportunities[:5],
    })
rows.sort(key=lambda r:({"fail":0,"pending":1,"unknown":1,"pass":2}.get(r["jeryu_gate"],1), r["name"]))
out={
    "generated_at_note":f"universe-board.sh FleetBoard-compatible operational projection at epoch {int(now)}; score/caps/hard findings remain owned by Jankurai",
    "schema":"jeryu.universe-board.fleet-projection.v1",
    "repos":rows,
    "totals":{
        "repo_count":len(rows),
        "audited":0,
        "failed":0,
        "min_score":None,
        "max_score":None,
        "average_score":None,
        "total_hard_findings":0,
        "below_threshold":0,
    },
    "errors":[],
}
print(json.dumps(out))
PY

[[ -s "$tmp/data.json" ]] || die "universe-board: aggregation produced no data"

if [[ "$do_json" == "1" ]]; then mkdir -p "$(dirname "$OUT_JSON")"; cp "$tmp/data.json" "$OUT_JSON"; ok "universe-board: wrote $OUT_JSON"; fi

if [[ "$do_html" == "1" ]]; then
  mkdir -p "$(dirname "$OUT_HTML")"
  python3 - "$OUT_HTML" "$tmp/data.json" <<'PY'
import sys, json, datetime
out=sys.argv[1]; d=json.load(open(sys.argv[2]))
def ago(s):
    if s is None: return "—"
    if s<90: return f"{s}s"
    if s<5400: return f"{s//60}m"
    if s<172800: return f"{s//3600}h"
    return f"{s//86400}d"
COL={"pass":"#1a7f37","fail":"#cf222e","pending":"#9a6700","unknown":"#9a6700"}
t=d["totals"]
counts={k:sum(r.get("jeryu_gate")==k for r in d["repos"]) for k in ("pass","fail","pending","unknown")}
def stages(a):
    return ",".join(k for k in ("local","dev_canary","prod") if a.get(k)=="signed")
rows=[]
for r in d["repos"]:
    art=r.get("artifact_state") or {}
    rs=r.get("runner_hint")
    runner=f'<span style="color:#bf3989">⟳ {rs}</span>' if r.get("runner_busy") else "·"
    rows.append(f'<tr style="border-left:4px solid {COL.get(r["jeryu_gate"],"#8c959f")}">'
        f'<td><b>{r["name"]}</b></td><td><code>{(r.get("head_sha") or "—")[:12]}</code></td><td>{r.get("version") or "n/a"}</td>'
        f'<td>{r["jeryu_gate"]}</td><td>{ago(r.get("main_ci_age_seconds"))}</td>'
        f'<td><code>{art.get("latest_sha") or "—"}</code> {stages(art)}</td>'
        f'<td>{runner}</td></tr>')
html=f"""<!doctype html><meta charset=utf-8><meta http-equiv=refresh content=60>
<title>jeryu universe</title>
<style>body{{font:13px ui-monospace,Menlo,monospace;background:#0d1117;color:#c9d1d9;margin:18px}}
h1{{font-size:18px}} .sub{{color:#8b949e}} table{{border-collapse:collapse;width:100%;margin-top:10px}}
th,td{{padding:5px 9px;text-align:left;border-bottom:1px solid #21262d}} th{{color:#8b949e;font-weight:600}}
code{{color:#79c0ff}}</style>
<h1>jeryu mission control — universe</h1>
<div class=sub>{t['repo_count']} repos · <span style="color:#1a7f37">{counts['pass']} pass</span> · <span style="color:#cf222e">{counts['fail']} fail</span> · <span style="color:#9a6700">{counts['pending'] + counts['unknown']} pending/unknown</span> · {d['schema']} · auto-refresh 60s</div>
<table><tr><th>repo</th><th>head</th><th>version</th><th>gate</th><th>last CI</th><th>last signed binary</th><th>runner</th></tr>
{''.join(rows)}</table>"""
open(out,"w").write(html)
print(f"wrote {out}", file=sys.stderr)
PY
  ok "universe-board: wrote $OUT_HTML"
fi

if [[ "$do_print" == "1" ]]; then
  python3 - "$tmp/data.json" <<'PY'
import sys, json
d=json.load(open(sys.argv[1])); t=d["totals"]
def ago(s):
    return "—" if s is None else (f"{s}s" if s<90 else f"{s//60}m" if s<5400 else f"{s//3600}h" if s<172800 else f"{s//86400}d")
counts={k:sum(r.get("jeryu_gate")==k for r in d["repos"]) for k in ("pass","fail","pending","unknown")}
print(f'UNIVERSE  {t["repo_count"]} repos  pass={counts["pass"]} fail={counts["fail"]} pending={counts["pending"] + counts["unknown"]}')
print(f'{"REPO":22}{"HEAD":14}{"VER":10}{"GATE":9}{"CI-AGE":8}{"BINARY":15}RUNNER')
for r in d["repos"]:
    lb=(r.get("artifact_state") or {}).get("latest_sha") or "—"
    runner=(r.get("runner_hint") or "idle").replace("process observation: ","")
    print(f'{r["name"]:22}{(r.get("head_sha") or "—")[:12]:14}{str(r.get("version") or "n/a")[:9]:10}{r["jeryu_gate"]:9}{ago(r.get("main_ci_age_seconds")):8}{lb:15}{runner}')
PY
fi
