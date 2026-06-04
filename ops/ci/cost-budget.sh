#!/usr/bin/env bash
set -Eeuo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

cd "$ROOT_DIR"
mkdir -p target/jankurai

log "cost-budget: validating local zero-spend manifest"
cargo run -q -p jmcp-ci-tools -- cost-budget

log "cost-budget: complete"
