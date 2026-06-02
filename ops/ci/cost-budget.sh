#!/usr/bin/env bash
set -Eeuo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

cd "$ROOT_DIR"
mkdir -p target/jankurai

log "cost-budget: validating local zero-spend manifest"
python3 - <<'PY'
import json
from pathlib import Path
import tomllib

root = Path(".")
manifest_path = root / "agent/cost-budget.toml"
manifest = tomllib.loads(manifest_path.read_text())
required = {
    "default_external_spend_usd": 0,
    "default_network_spend_usd": 0,
}
for key, expected in required.items():
    if manifest.get(key) != expected:
        raise SystemExit(f"{key} must be {expected}")
quota_caps = manifest.get("quota_caps", {})
for key in ("external_api_usd", "telegram_paid_usd", "model_api_usd"):
    if quota_caps.get(key) != 0:
        raise SystemExit(f"quota cap {key} must be zero by default")
stop_conditions = manifest.get("stop_conditions", {})
for key in ("on_missing_receipt", "on_unknown_paid_tool", "on_quota_exceeded", "on_kill_switch"):
    if stop_conditions.get(key) is not True:
        raise SystemExit(f"stop condition {key} must be true")
receipt = {
    "ok": True,
    "manifest": str(manifest_path),
    "default_external_spend_usd": manifest["default_external_spend_usd"],
    "quota_caps": quota_caps,
    "kill_switch_env": manifest["kill_switch_env"],
    "stop_conditions": stop_conditions,
}
Path("target/jankurai/cost-budget.json").write_text(json.dumps(receipt, indent=2) + "\n")
PY

log "cost-budget: complete"
