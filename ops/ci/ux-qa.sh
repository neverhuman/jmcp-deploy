#!/usr/bin/env bash
set -Eeuo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

cd "$ROOT_DIR"
mkdir -p target/jankurai

log "ux-qa: deploy owns no rendered web surface; verifying manifest links to jmcp-web"
python3 - <<'PY'
import json
from pathlib import Path

manifest = Path("repos.manifest.toml").read_text()
if "jmcp-web" not in manifest:
    raise SystemExit("repos.manifest.toml must include jmcp-web")
evidence = json.loads(Path("agent/ux-qa-evidence.json").read_text())
receipt = {
    "ok": True,
    "web_surface_owner": evidence["delegated_repo"],
    "deploy_surface": "split orchestration",
    "manifest": "repos.manifest.toml",
    "evidence": "agent/ux-qa-evidence.json",
    "playwright_visual": evidence["playwright_visual"],
    "accessibility": evidence["accessibility"],
    "api_mocks": evidence["api_mocks"],
}
Path("target/jankurai/ux-qa.json").write_text(json.dumps(receipt, indent=2) + "\n")
PY

log "ux-qa: complete"
