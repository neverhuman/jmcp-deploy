#!/usr/bin/env bash
set -Eeuo pipefail

# tools/security-lane.sh is the canonical security wrapper for Jankurai.
# It delegates to the maintained lane that runs gitleaks detect, cargo audit,
# npm audit, zizmor workflow linting, and syft SBOM generation when available.
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec "$ROOT_DIR/ops/ci/security.sh"
