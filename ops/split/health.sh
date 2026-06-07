#!/usr/bin/env bash
set -euo pipefail

ROOT="${JMCP_SPLIT_ROOT:-/home/ubuntu/jmcp-split}"
MANIFEST="${JMCP_SPLIT_MANIFEST:-$ROOT/repos.manifest.toml}"
JERYU_BASE="${JERYU_BASE:-http://127.0.0.1:8787}"
DEPLOY_DIR="$ROOT/jmcp-deploy"
if [[ ! -d "$DEPLOY_DIR/ops/split" ]]; then
  DEPLOY_DIR="$ROOT"
fi
OFFLINE=0
REQUIRE_JERYU=0

usage() {
  printf 'usage: %s [--offline|--require-jeryu]\n' "$0" >&2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --offline)
      OFFLINE=1
      ;;
    --require-jeryu)
      REQUIRE_JERYU=1
      ;;
    *)
      usage
      exit 2
      ;;
  esac
  shift
done

if [[ "$OFFLINE" == "1" && "$REQUIRE_JERYU" == "1" ]]; then
  usage
  exit 2
fi

"$DEPLOY_DIR/ops/split/manifest.sh" --manifest "$MANIFEST" >/dev/null

if [[ "$OFFLINE" == "1" ]]; then
  printf 'split_manifest=ok mode=offline manifest=%s\n' "$MANIFEST"
  exit 0
fi

fail=0
while IFS='|' read -r name path github_slug jeryu_slug; do
  if [[ ! -d "$path/.git" ]]; then
    printf 'missing_git_repo name=%s path=%s\n' "$name" "$path" >&2
    fail=1
    continue
  fi
  if ! git -C "$path" rev-parse --verify main >/dev/null 2>&1; then
    printf 'missing_main name=%s\n' "$name" >&2
    fail=1
  fi
  if ! git -C "$path" remote get-url github >/dev/null 2>&1; then
    printf 'missing_github_remote name=%s slug=%s\n' "$name" "$github_slug" >&2
    fail=1
  fi
  if ! git -C "$path" remote get-url jeryu >/dev/null 2>&1; then
    printf 'missing_jeryu_remote name=%s slug=%s\n' "$name" "$jeryu_slug" >&2
    fail=1
  fi
done < <("$DEPLOY_DIR/ops/split/manifest.sh" --manifest "$MANIFEST")

if curl -fsS --max-time 5 "$JERYU_BASE/health" >/dev/null 2>&1; then
  printf 'jeryu_api=ok base=%s\n' "$JERYU_BASE"
else
  printf 'jeryu_api=down base=%s\n' "$JERYU_BASE" >&2
  if [[ "$REQUIRE_JERYU" == "1" ]]; then
    fail=1
  fi
fi

exit "$fail"
