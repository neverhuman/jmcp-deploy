#!/usr/bin/env bash
# jeryu-ctl/jankurai-waste.sh — "reduce-LOC / promote-more-tool-use" waste REPORT (Cluster 4.4).
# Reads each repo's cached .jankurai/repo-score.json copy_code.summary + tool_adoption (informational —
# copy-code is not a score cap today) and writes ~/.jankurai/waste-report.{json,md}: per-repo redundant
# LOC + tool-adoption gap. Hand the rollup to Codex to set a HLT-WASTE engine cap budget. Never blocks.
# usage: jankurai-waste.sh [--print]
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; . "$HERE/lib.sh"; . "$HERE/manifest.sh"
OUT_JSON="${JANKURAI_WASTE_JSON:-/home/ubuntu/.jankurai/waste-report.json}"
OUT_MD="${JANKURAI_WASTE_MD:-/home/ubuntu/.jankurai/waste-report.md}"
do_print=0; [[ "${1:-}" == "--print" ]] && do_print=1
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
manifest_repos --rows 2>/dev/null > "$tmp/rows"
python3 - "$tmp/rows" "$OUT_JSON" "$OUT_MD" "$do_print" <<'PY'
import sys, os, json
ROWS,OJ,OM,PR = sys.argv[1:5]
rows=[]
for line in open(ROWS):
    name,path,gslug,jslug=(line.strip().split("|")+["","","",""])[:4]
    if not name or not path: continue
    sj=os.path.join(path,".jankurai","repo-score.json")
    if not os.path.isfile(sj): continue
    try: d=json.load(open(sj))
    except (OSError, json.JSONDecodeError): continue
    cc=(d.get("copy_code") or {}).get("summary") or {}
    ta=d.get("tool_adoption") or {}
    miss=[ (m if isinstance(m,str) else (m.get("tool") or m.get("id") or "")) for m in (ta.get("missing") or []) ]
    rows.append({"repo":name,"redundant_lines":cc.get("total_redundant_lines",0),
        "duplicate_lines":cc.get("duplicate_lines",0),"hard_dup_classes":cc.get("hard_classes",0),
        "tool_applicable":ta.get("applicable_count",0),"tool_ci_evidence":ta.get("ci_evidence_count",0),
        "tool_adoption_gap":max(0,(ta.get("applicable_count",0)-ta.get("ci_evidence_count",0))),
        "missing_tools":miss})
rows.sort(key=lambda r:(-r["redundant_lines"], -r["tool_adoption_gap"]))
roll={"repos_reported":len(rows),
      "total_redundant_lines":sum(r["redundant_lines"] for r in rows),
      "total_tool_adoption_gap":sum(r["tool_adoption_gap"] for r in rows)}
json.dump({"schema":"jankurai.waste.v1","rollup":roll,"repos":rows}, open(OJ,"w"), indent=2)
with open(OM,"w") as f:
    f.write(f"# jankurai waste report\n\n{len(rows)} repos · {roll['total_redundant_lines']} redundant LOC · {roll['total_tool_adoption_gap']} tool-adoption gaps\n\n")
    f.write("| repo | redundant LOC | dup classes | tool gap | missing tools |\n|---|--:|--:|--:|---|\n")
    for r in rows: f.write(f"| {r['repo']} | {r['redundant_lines']} | {r['hard_dup_classes']} | {r['tool_adoption_gap']} | {', '.join(r['missing_tools'][:4])} |\n")
if PR=="1":
    print(f"WASTE  {len(rows)} repos  redundant_LOC={roll['total_redundant_lines']}  tool_gap={roll['total_tool_adoption_gap']}")
    print(f"{'REPO':22}{'REDUNDANT':11}{'DUP-CLS':9}{'TOOL-GAP':9}MISSING")
    for r in rows: print(f"{r['repo']:22}{r['redundant_lines']:<11}{r['hard_dup_classes']:<9}{r['tool_adoption_gap']:<9}{','.join(r['missing_tools'][:3])}")
PY
ok "jankurai-waste: wrote $OUT_JSON + $OUT_MD"
