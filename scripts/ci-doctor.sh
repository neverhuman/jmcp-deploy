#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

printf '[jmcp-ci] doctor: repository %s\n' "$ROOT_DIR"

for tool in bash node npm cargo just gitleaks cargo-audit cargo-deny zizmor syft actionlint; do
  if command -v "$tool" >/dev/null 2>&1; then
    version="$("$tool" --version 2>/dev/null | head -n 1 || true)"
    printf '[jmcp-ci] tool %-12s %s\n' "$tool" "${version:-present}"
  else
    printf '[jmcp-ci][warn] tool %-12s missing\n' "$tool"
  fi
done

printf '[jmcp-ci] manifests:'
for file in Cargo.toml Cargo.lock package.json package-lock.json deny.toml gitleaks.toml; do
  if [[ -e "$file" ]]; then
    printf ' %s' "$file"
  fi
done
printf '\n'
