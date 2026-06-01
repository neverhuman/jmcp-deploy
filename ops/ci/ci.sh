#!/usr/bin/env bash
set -Eeuo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

cd "$ROOT_DIR"

"${ROOT_DIR}/ops/ci/fast.sh"

if repo_has Cargo.toml && ! has cargo; then
  missing_tool cargo "Rust tests"
elif cargo_workspace_ready; then
  log "ci: running Rust tests"
  cargo test --workspace --all-targets
elif repo_has Cargo.toml; then
  warn "skipping Rust tests: Cargo workspace metadata is not ready"
else
  warn "skipping Rust tests: Cargo.toml not present"
fi

if repo_has package.json && has npm; then
  log "ci: running npm tests"
  npm test
elif repo_has package.json; then
  missing_tool npm "npm tests"
fi

"${ROOT_DIR}/ops/ci/conformance.sh"

log "ci: complete"
