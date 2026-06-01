#!/usr/bin/env bash
set -Eeuo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

cd "$ROOT_DIR"

log "fast: checking shell syntax"
while IFS= read -r script; do
  bash -n "$script"
done < <(find scripts ops/ci -type f -name '*.sh' | sort)

log "fast: validating JSON files"
if has node; then
  node <<'NODE'
const fs = require('fs');
const path = require('path');

function walk(dir, out = []) {
  if (!fs.existsSync(dir)) return out;
  for (const name of fs.readdirSync(dir)) {
    const full = path.join(dir, name);
    const stat = fs.statSync(full);
    if (stat.isDirectory()) walk(full, out);
    else if (name.endsWith('.json')) out.push(full);
  }
  return out;
}

const files = [
  ...walk('schemas'),
  ...['package.json', 'package-lock.json'].filter((file) => fs.existsSync(file)),
];

for (const file of files) {
  JSON.parse(fs.readFileSync(file, 'utf8'));
}

console.log(`validated ${files.length} JSON file(s)`);
NODE
else
  missing_tool node "JSON validation"
fi

if repo_has Cargo.toml && ! has cargo; then
  missing_tool cargo "Rust formatting and checks"
elif cargo_workspace_ready; then
  log "fast: checking Rust workspace"
  cargo fmt --all -- --check
  cargo check --workspace --all-targets
elif repo_has Cargo.toml; then
  warn "skipping Rust checks: Cargo workspace metadata is not ready"
else
  warn "skipping Rust checks: Cargo.toml not present"
fi

if repo_has package-lock.json && has npm; then
  log "fast: verifying npm lockfile"
  npm ci --ignore-scripts --no-audit --no-fund
elif repo_has package-lock.json; then
  missing_tool npm "npm lockfile verification"
fi

if has actionlint; then
  log "fast: linting GitHub Actions"
  actionlint
else
  missing_tool actionlint "GitHub Actions linting"
fi

log "fast: complete"
