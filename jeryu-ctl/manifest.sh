#!/usr/bin/env bash
# jeryu-ctl/manifest.sh — reader for repos.manifest.toml. Source it for the
# manifest_repos() helper, or run it as a CLI.
#
# manifest_repos [--wave N] [--max-wave N] [--onboarded true|false]
#                [--has-jeryu true|false] [--field FIELD]
#   prints one line per matching repo (default FIELD=name).
#
# Examples:
#   manifest_repos --field path                 # all repo paths
#   manifest_repos --wave 0 --field jeryu_slug   # canary jeryu slug
#   manifest_repos --max-wave 1 --field github_slug
REPOS_MANIFEST="${REPOS_MANIFEST:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/repos.manifest.toml}"

manifest_repos() {
  python3 - "$REPOS_MANIFEST" "$@" <<'PY'
import sys
try:
    import tomllib
except ModuleNotFoundError:
    import tomli as tomllib  # py<3.11 compatibility
path = sys.argv[1]; args = sys.argv[2:]
wave = max_wave = onboarded = has_jeryu = None; field = "name"; rows = False
i = 0
while i < len(args):
    a = args[i]
    if a == "--wave": wave = int(args[i+1]); i += 2
    elif a == "--max-wave": max_wave = int(args[i+1]); i += 2
    elif a == "--onboarded": onboarded = (args[i+1].lower() == "true"); i += 2
    elif a == "--has-jeryu": has_jeryu = (args[i+1].lower() == "true"); i += 2
    elif a == "--field": field = args[i+1]; i += 2
    elif a == "--rows": rows = True; i += 1   # emit name|path|github_slug|jeryu_slug
    else: sys.exit("manifest: unknown arg %s" % a)
with open(path, "rb") as f:
    data = tomllib.load(f)
for r in data.get("repo", []):
    if wave is not None and r.get("rollout_wave") != wave: continue
    if max_wave is not None and r.get("rollout_wave", 99) > max_wave: continue
    if onboarded is not None and bool(r.get("onboarded")) != onboarded: continue
    if has_jeryu is not None and bool(r.get("has_jeryu_std")) != has_jeryu: continue
    if rows:
        print("%s|%s|%s|%s" % (r.get("name",""), r.get("path",""), r.get("github_slug",""), r.get("jeryu_slug","")))
    else:
        v = r.get(field, "")
        print(v if not isinstance(v, bool) else str(v).lower())
PY
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then manifest_repos "$@"; fi
