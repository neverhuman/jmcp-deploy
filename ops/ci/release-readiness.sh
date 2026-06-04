#!/usr/bin/env bash
set -Eeuo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

cd "$ROOT_DIR"
mkdir -p target/jankurai

log "release-readiness: validating release evidence surface"
cargo run -q -p jmcp-ci-tools -- release-readiness

log "release-readiness: complete"
