#!/usr/bin/env bash
set -euo pipefail

ops/split/manifest.sh --manifest repos.manifest.toml >/dev/null
ops/split/health.sh
ops/split/launch.sh --dry-run
