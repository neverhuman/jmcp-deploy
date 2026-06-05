#!/usr/bin/env bash
set -euo pipefail

ROOT="${JMCP_SPLIT_ROOT:-/home/ubuntu/jmcp-split}"
DRY_RUN=1
if [[ "${1:-}" == "--run" ]]; then
  DRY_RUN=0
elif [[ "${1:-}" != "" && "${1:-}" != "--dry-run" ]]; then
  printf 'usage: %s [--dry-run|--run]\n' "$0" >&2
  exit 2
fi

core_cmd=(cargo run -p jmcpd)
web_cmd=(npm --workspace @jmcp/cockpit run dev -- --host 127.0.0.1 --port "${JMCP_WEB_PORT:-5173}")
talk_cmd=(bash services/speech/selftest.sh)

emit() {
  local name="$1" dir="$2"
  shift 2
  printf '%s cwd=%s cmd=' "$name" "$dir"
  printf '%q ' "$@"
  printf '\n'
}

emit core "$ROOT/jmcp-core" "${core_cmd[@]}"
emit web "$ROOT/jmcp-web" "${web_cmd[@]}"
emit talk "$ROOT/jmcp-talk" "${talk_cmd[@]}"

if [[ "$DRY_RUN" == "1" ]]; then
  exit 0
fi

(cd "$ROOT/jmcp-core" && "${core_cmd[@]}") &
(cd "$ROOT/jmcp-web" && "${web_cmd[@]}") &
(cd "$ROOT/jmcp-talk" && "${talk_cmd[@]}") &
wait
