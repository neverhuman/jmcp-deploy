#!/usr/bin/env bash
set -euo pipefail

python3 ops/split/manifest.py --manifest repos.manifest.toml >/dev/null
ops/split/health.sh
ops/split/launch.sh --dry-run
