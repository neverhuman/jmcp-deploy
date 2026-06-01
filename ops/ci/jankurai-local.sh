#!/usr/bin/env bash
set -Eeuo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

cd "$ROOT_DIR"

log "jankurai-local: running local parity gates"
"${ROOT_DIR}/ops/ci/fast.sh"
"${ROOT_DIR}/ops/ci/conformance.sh"
"${ROOT_DIR}/ops/ci/security.sh"
log "jankurai-local: complete"
