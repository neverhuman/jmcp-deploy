#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
STRICT_TOOLS="${JMCP_STRICT_TOOLS:-0}"

log() {
  printf '[jmcp-ci] %s\n' "$*"
}

warn() {
  printf '[jmcp-ci][warn] %s\n' "$*" >&2
}

fail() {
  printf '[jmcp-ci][error] %s\n' "$*" >&2
  exit 1
}

has() {
  command -v "$1" >/dev/null 2>&1
}

missing_tool() {
  local tool="$1"
  local reason="${2:-required for this check}"

  if [[ "$STRICT_TOOLS" == "1" ]]; then
    fail "missing tool: ${tool} (${reason}); install it or set JMCP_STRICT_TOOLS=0 for bootstrap"
  fi

  warn "skipping ${tool}: not installed (${reason})"
  return 0
}

run_if_has() {
  local tool="$1"
  local reason="$2"
  shift 2

  if ! has "$tool"; then
    missing_tool "$tool" "$reason"
    return 0
  fi

  "$@"
}

repo_has() {
  [[ -e "${ROOT_DIR}/$1" ]]
}

cargo_workspace_ready() {
  repo_has Cargo.toml || return 1
  has cargo || return 1
  cargo metadata --no-deps --format-version 1 >/dev/null 2>&1
}
