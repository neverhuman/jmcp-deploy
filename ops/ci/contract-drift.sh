#!/usr/bin/env bash
set -Eeuo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

cd "$ROOT_DIR"

log "contract-drift: verifying split manifest wiring"
python3 - <<'PY'
from pathlib import Path

root = Path(".")
manifest = root / "repos.manifest.toml"
launcher = root / "ops/split/launch.sh"
health = root / "ops/split/health.sh"
smoke = root / "ops/split/smoke.sh"

for path in (manifest, launcher, health, smoke):
    if not path.exists():
        raise SystemExit(f"missing deploy contract surface: {path}")

text = manifest.read_text()
for repo in ("jmcp-core", "jmcp-web", "jmcp-talk", "jmcp-deploy"):
    if repo not in text:
        raise SystemExit(f"repos.manifest.toml missing {repo}")
    if f"jeryu/{repo}.git" not in text:
        raise SystemExit(f"repos.manifest.toml missing local Jeryu remote for {repo}")

launch_text = launcher.read_text()
for term in ("JMCP_SPLIT_MANIFEST", "JMCP_SPLIT_ROOT", "--dry-run"):
    if term not in launch_text:
        raise SystemExit(f"launch.sh missing {term}")

if "--offline" not in health.read_text():
    raise SystemExit("health.sh must keep an offline proof mode")
if "JMCP_SPLIT_MANIFEST" not in smoke.read_text():
    raise SystemExit("smoke.sh must route through the split manifest")
PY

log "contract-drift: complete"
