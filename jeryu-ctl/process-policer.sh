#!/usr/bin/env bash
# jeryu-ctl/process-policer.sh — LIVE stdout/stderr policing (Cluster 1C).
#
# Snapshots the live state of the autonomous system every POLICER_INTERVAL seconds: the loop
# (jeryu-poll), the autonomy daemon, jeryu-api, the self-hosted GitHub runners (systemd user units),
# and the background release/deploy logs. Classifies each as running | stuck | errored | exited via
# journald + log-tail heuristics, writes ~/.jeryu/process-observations.json (the cache the universe
# board reads), and POSTs ProcessObservations to JMCP /process-observations on state CHANGE (deduped,
# fail-open — works fully via the local cache when jmcpd is down/stale).
#
# usage: process-policer.sh [--once]    (no arg = loop forever; the systemd service runs it)
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; . "$HERE/lib.sh"
JMCP_BASE="${JMCP_BASE:-http://127.0.0.1:18877}"
CACHE="${PROCESS_OBS_CACHE:-/home/ubuntu/.jeryu/process-observations.json}"
INTERVAL="${POLICER_INTERVAL:-20}"
STATE_DIR="${JERYU_CTL_STATE:-/home/ubuntu/.jeryu/agent-review}"
once=0; [[ "${1:-}" == "--once" ]] && once=1
mkdir -p "$(dirname "$CACHE")" 2>/dev/null || true

snapshot(){
  python3 - "$STATE_DIR" <<'PY'
import sys, os, json, subprocess, time, re, glob
STATE_DIR=sys.argv[1]
STUCK=int(os.environ.get("POLICER_STUCK_SECONDS","600"))
LONGRUN=int(os.environ.get("POLICER_LONGRUN_SECONDS","1200"))
ERR_RE=re.compile(os.environ.get("POLICER_ERROR_REGEX", r"error\[|panicked|FAILED|fatal:|leaks found|rc=[1-9]|exit code [1-9]|Traceback|denied"), re.I)
now=time.time()
def sh(*a):
    try: return subprocess.run(a,capture_output=True,text=True,timeout=10).stdout
    except Exception: return ""
def is_active(u): return sh("systemctl","--user","is-active",u).strip()
def last_line_ts(u):
    out=sh("systemctl","--user","show",u,"-p","ActiveEnterTimestamp","-p","ExecMainStartTimestamp")
    # journald last entry time
    j=sh("journalctl","--user","-u",u,"-n","1","-o","short-unix","--no-pager").strip().split()
    try: return float(j[0]) if j else None
    except Exception: return None
def recent_text(u,secs):
    return sh("journalctl","--user","-u",u,"--since",f"-{secs}s","-o","cat","--no-pager")

obs=[]
def emit(key,status,stuck,diag,cmd=None,started=None):
    obs.append({"process_key":key,"command":cmd,"status":status,"pty":None,"stuck":stuck,
                "diagnostic_class":diag,"started_at":started,"updated_at":int(now)})

RUNNER_RE=re.compile(r"actions\.runner\.", re.I)
JOB_START=re.compile(r"Running job:", re.I)
JOB_DONE =re.compile(r"completed with result|Listening for Jobs|has received a shutdown", re.I)

def journal(u):  # [(ts, msg)] most recent ~40 lines
    out=[]
    for l in sh("journalctl","--user","-u",u,"-n","40","-o","short-unix","--no-pager").splitlines():
        p=l.split(None,1)
        try: out.append((float(p[0]), p[1] if len(p)>1 else ""))
        except Exception: pass
    return out

# core + runner units (only ones that are active are worth policing)
units=set(["jeryu-poll.service","autonomy-daemon.service","jeryu-api.service"])
for line in sh("systemctl","--user","list-units","--no-legend","--plain","--all").splitlines():
    u=(line.split()[:1] or [""])[0]
    if u.endswith(".service") and re.search(r"runner|jeryu-poll|autonomy", u, re.I): units.add(u)
for u in sorted(units):
    if is_active(u) not in ("active","activating"): continue   # idle/inactive -> nothing to police
    J=journal(u); last_ts=J[-1][0] if J else None
    last_start=max((ts for ts,m in J if JOB_START.search(m)), default=None)
    last_done =max((ts for ts,m in J if JOB_DONE.search(m)),  default=None)
    last_err  =max((ts for ts,m in J if ERR_RE.search(m)),    default=None)
    if RUNNER_RE.search(u):
        # a runner is only interesting while it is EXECUTING a job (not idle-listening)
        job_active = last_start is not None and (last_done is None or last_start>last_done)
        if not job_active: continue
        if last_err is not None and last_err>=last_start: emit(u,"errored",False,"error-line",started=int(last_start))
        elif now-last_start>STUCK: emit(u,"stuck",True,"stuck-no-output",started=int(last_start))
        else: emit(u,"running",False,None,started=int(last_start))
    elif re.search(r"jeryu-api|autonomy", u):
        # steady servers/daemons: quiet != stuck. Only flag a genuine error line, never "running"/"stuck".
        if last_err is not None and last_ts is not None and last_err>=last_ts-5: emit(u,"errored",False,"error-line")
    else:  # jeryu-poll (oneshot): a run that is active+quiet past STUCK is genuinely hung
        quiet=(now-last_ts) if last_ts else None
        if last_err is not None and last_ts is not None and last_err>=last_ts-5: emit(u,"errored",False,"error-line")
        elif quiet is not None and quiet>STUCK: emit(u,"stuck",True,"stuck-no-output")
        else: emit(u,"running",False,None)

# 2) background release/deploy logs -> per-repo (owner__repo) signals
for log in glob.glob(f"{STATE_DIR}/*/deploy.log")+glob.glob(f"{STATE_DIR}/*/*.release.log")+glob.glob(f"{STATE_DIR}/*/*.promote.log"):
    try: age=now-os.path.getmtime(log)
    except Exception: continue
    if age>LONGRUN: continue   # only recently-active deploys
    key=os.path.basename(os.path.dirname(log))   # owner__repo
    try:
        with open(log,errors="ignore") as f:
            f.seek(max(0,os.path.getsize(log)-4000)); tail=f.read()
    except Exception: tail=""
    if ERR_RE.search(tail):
        emit(key,"errored",False,"error-line","deploy")
    elif age<INTERVAL*3:
        emit(key,"running",False,None,"deploy")

print(json.dumps(obs))
PY
}

post_obs(){  # best-effort POST to JMCP; fail-open
  curl -fsS --max-time 5 -X POST "$JMCP_BASE/process-observations" \
    -H 'content-type: application/json' -d "$1" >/dev/null 2>&1 || return 0
}

cycle(){
  local new; new="$(snapshot 2>/dev/null)"; [[ -n "$new" ]] || return 0
  # diff vs previous cache (by process_key -> status); POST changed
  local prev="[]"; [[ -f "$CACHE" ]] && prev="$(cat "$CACHE" 2>/dev/null || echo '[]')"
  python3 - "$new" "$prev" <<'PY' | while IFS= read -r line; do post_obs "$line"; done
import sys, json, uuid, datetime
new=json.loads(sys.argv[1]); prev=json.loads(sys.argv[2])
pp={o["process_key"]:o.get("status") for o in prev}
# map our cache statuses -> the jmcp ProcessStatus enum (snake_case); datetimes -> RFC3339; add a Uuid.
SMAP={"errored":"failed","exited":"completed"}
def rfc(e): return datetime.datetime.fromtimestamp(e, datetime.timezone.utc).isoformat().replace("+00:00","Z") if e else None
def now_rfc(): return datetime.datetime.now(datetime.timezone.utc).isoformat().replace("+00:00","Z")
for o in new:
    if pp.get(o["process_key"])==o.get("status"): continue
    # the jmcp ProcessObservation struct is camelCase (status enum is snake_case; datetimes RFC3339).
    route={"id":str(uuid.uuid4()),"processKey":o["process_key"],"command":o.get("command"),
           "status":SMAP.get(o.get("status"),o.get("status")),"pty":o.get("pty"),"stuck":bool(o.get("stuck")),
           "diagnosticClass":o.get("diagnostic_class"),"startedAt":rfc(o.get("started_at")),
           "updatedAt":rfc(o.get("updated_at")) or now_rfc()}
    print(json.dumps(route))
PY
  printf '%s\n' "$new" > "$CACHE.tmp" && mv "$CACHE.tmp" "$CACHE"
  local n; n="$(python3 -c 'import json,sys;print(len(json.load(open(sys.argv[1]))))' "$CACHE" 2>/dev/null || echo 0)"
  [[ "$once" == "1" ]] && say "policer: $n active observation(s) -> $CACHE"
}

if [[ "$once" == "1" ]]; then cycle; exit 0; fi
say "process-policer: starting (interval=${INTERVAL}s, cache=$CACHE, jmcp=$JMCP_BASE)"
while true; do cycle || true; sleep "$INTERVAL"; done
