#!/usr/bin/env bash
set -Eeuo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

cd "$ROOT_DIR"
mkdir -p .artifacts/security

if has gitleaks; then
  log "security: running gitleaks"
  gitleaks detect --source . --config gitleaks.toml --no-banner --redact --no-git
else
  missing_tool gitleaks "secret scanning"
fi

if repo_has Cargo.lock; then
  log "security: running cargo-audit"
  run_if_has cargo-audit "RustSec advisory scanning" cargo audit --ignore RUSTSEC-2024-0436 --ignore RUSTSEC-2026-0002
elif repo_has Cargo.toml; then
  warn "skipping cargo-audit: Cargo.lock not present"
else
  warn "skipping cargo-audit: Cargo workspace not present"
fi

if repo_has Cargo.toml && ! has cargo; then
  missing_tool cargo "Rust dependency policy"
elif cargo_workspace_ready; then
  log "security: running cargo-deny"
  run_if_has cargo-deny "Rust dependency policy" cargo deny check
elif repo_has Cargo.toml; then
  warn "skipping cargo-deny: Cargo workspace metadata is not ready"
else
  warn "skipping cargo-deny: Cargo workspace not present"
fi

if repo_has package-lock.json && has npm; then
  log "security: running npm audit"
  npm audit --audit-level=high
elif repo_has package-lock.json; then
  missing_tool npm "npm advisory scanning"
else
  warn "skipping npm audit: package-lock.json not present"
fi

if has zizmor; then
  log "security: running zizmor"
  zizmor .github/workflows
else
  missing_tool zizmor "GitHub Actions security linting"
fi

if has syft; then
  log "security: generating SBOM"
  syft dir:. -o spdx-json=.artifacts/security/jmcp.spdx.json
else
  missing_tool syft "SBOM generation"
fi

log "security: complete"
