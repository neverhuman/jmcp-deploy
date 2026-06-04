#!/usr/bin/env bash
set -Eeuo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

cd "$ROOT_DIR"

log "contract-drift: verifying generated event contract shape"
cargo run -q -p jmcp-ci-tools -- contract-drift

log "contract-drift: checking HTTP route and streaming contract coverage"
cargo test -p jmcp-api --test openapi_route_coverage --locked

log "contract-drift: complete"
