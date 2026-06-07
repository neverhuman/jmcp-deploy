#!/usr/bin/env bash
set -euo pipefail

ROOT="${JMCP_SPLIT_ROOT:-/home/ubuntu/jmcp-split}"
SOURCE_ROOT="${JMCP_SOURCE_ROOT:-/home/ubuntu/jmcp}"
CORE_REPO="${JMCP_CORE_REPO:-$ROOT/jmcp-core}"
WEB_REPO="${JMCP_WEB_REPO:-$ROOT/jmcp-web}"
TALK_REPO="${JMCP_TALK_REPO:-$ROOT/jmcp-talk}"
LIVE_ROOT="${JMCP_LIVE_ROOT:-$ROOT/.live}"
LOG_DIR="${JMCP_LIVE_LOG_DIR:-$LIVE_ROOT/logs}"
CORE_BIND="${JMCP_API_BIND:-127.0.0.1:18877}"
CORE_URL="${JMCP_API_URL:-http://127.0.0.1:18877}"
COCKPIT_HOST="${JMCP_COCKPIT_HOST:-127.0.0.1}"
COCKPIT_PORT="${JMCP_COCKPIT_PORT:-8080}"
VOICE_BIND="${JMCP_TALK_VOICE_BIND:-127.0.0.1:8040}"
VOICE_TARGET="${VITE_VOICE_TARGET:-http://127.0.0.1:${VOICE_BIND##*:}}"
MINICPM_TARGET="${VITE_MINICPM_TARGET:-http://127.0.0.1:8041}"
WAIT_SECONDS="${JMCP_LIVE_WAIT_SECONDS:-300}"
KILL_STALE="${JMCP_LIVE_KILL_STALE:-1}"
DRY_RUN=1
if [[ "${1:-}" == "--run" ]]; then
  DRY_RUN=0
elif [[ "${1:-}" != "" && "${1:-}" != "--dry-run" ]]; then
  printf 'usage: %s [--dry-run|--run]\n' "$0" >&2
  exit 2
fi

core_cmd=(
  env RUST_LOG="${RUST_LOG:-info}"
  cargo run -p jmcpd -- --listen "$CORE_BIND" --database "$LIVE_ROOT/jmcp-live.sqlite"
)
web_cmd=(
  env
  JMCP_COCKPIT_HOST="$COCKPIT_HOST"
  JMCP_COCKPIT_PORT="$COCKPIT_PORT"
  VITE_JMCP_TARGET="$CORE_URL"
  VITE_VOICE_TARGET="$VOICE_TARGET"
  VITE_MINICPM_TARGET="$MINICPM_TARGET"
  VITE_JMCP_BASE="/jmcp"
  VITE_VOICE_BASE="/voice"
  VITE_VOICE_WS_BASE="/voice-ws"
  npm --workspace @jmcp/cockpit run dev -- --host "$COCKPIT_HOST" --port "$COCKPIT_PORT"
)
talk_cmd=(
  env
  JMCP_TALK_VOICE_BIND="$VOICE_BIND"
  JMCP_TALK_VOICE_LOG_DIR="$LOG_DIR"
  JMCP_TALK_AUDIO_DIR="${JMCP_TALK_AUDIO_DIR:-$LIVE_ROOT/audio}"
  JMCP_TALK_REALTIME_FOREGROUND=1
  bash services/llm/realtime-voice.sh
)

emit() {
  local name="$1" dir="$2"
  shift 2
  printf '%s cwd=%s cmd=' "$name" "$dir"
  printf '%q ' "$@"
  printf '\n'
}

port_from_url() {
  python3 - "$1" <<'PY'
import sys
from urllib.parse import urlparse
parsed = urlparse(sys.argv[1])
print(parsed.port or (443 if parsed.scheme == "https" else 80))
PY
}

port_from_bind() {
  local bind="$1"
  printf '%s\n' "${bind##*:}"
}

proc_cwd() {
  readlink "/proc/$1/cwd" 2>/dev/null || true
}

proc_cmdline() {
  cat "/proc/$1/cmdline" 2>/dev/null | tr '\0' ' ' || true
}

is_under_owned_root() {
  local path="$1"
  [[ "$path" == "$ROOT" || "$path" == "$ROOT/"* || "$path" == "$SOURCE_ROOT" || "$path" == "$SOURCE_ROOT/"* ]]
}

is_voice_model_cmd() {
  local cmd="$1"
  case "$cmd" in
    *"gateway.py"*|*"worker.py"*|*"llama-server"*|*"llama-omni-cli"*|\
    *"run-minicpm-o45.sh"*|*"MiniCPM-o-Demo"*|*"llama.cpp-omni"*|\
    *"vllm serve"*|*"run-llm.sh"*|*"realtime-voice.sh"*|\
    *"run-voice-gateway.sh"*|*"jmcp-voiced"*|\
    *"asr_sidecar.py"*|*"tts_sidecar.py"*|*"jmcp-speechd"*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

is_owned_voice_model_pid() {
  local pid="$1" cwd cmd
  [[ -r "/proc/$pid/cmdline" ]] || return 1
  cwd="$(proc_cwd "$pid")"
  cmd="$(proc_cmdline "$pid")"
  is_voice_model_cmd "$cmd" || return 1
  if is_under_owned_root "$cwd"; then
    return 0
  fi
  [[ "$cmd" == *"$ROOT"* || "$cmd" == *"$SOURCE_ROOT"* ]]
}

owned_voice_model_pids() {
  local entry pid
  set +e
  for entry in /proc/[0-9]*; do
    pid="${entry##*/}"
    if is_owned_voice_model_pid "$pid"; then
      printf '%s\n' "$pid"
    fi
  done
  set -e
}

cleanup_old_voice_models() {
  local pids pid
  mapfile -t pids < <(owned_voice_model_pids)
  [[ "${#pids[@]}" -gt 0 ]] || return 0
  printf 'old_jmcp_voice_model_pids=%s\n' "${pids[*]}"
  [[ "$KILL_STALE" == "1" ]] || return 0
  for pid in "${pids[@]}"; do
    kill -TERM "$pid" >/dev/null 2>&1 || true
  done
  sleep 2
  for pid in "${pids[@]}"; do
    if kill -0 "$pid" >/dev/null 2>&1; then
      kill -KILL "$pid" >/dev/null 2>&1 || true
    fi
  done
}

gpu_memory_snapshot() {
  if ! command -v nvidia-smi >/dev/null 2>&1; then
    printf 'gpu_memory=unavailable reason=nvidia-smi-missing\n'
    return 0
  fi
  nvidia-smi --query-gpu=memory.used,memory.total --format=csv,noheader,nounits \
    | awk '{gsub(/[[:space:]]/, "", $0); split($0,a,","); printf "gpu_memory_used_mb=%s gpu_memory_total_mb=%s\n", a[1], a[2]}'
}

assert_no_old_gpu_voice_models() {
  local row pid mem failed=0
  command -v nvidia-smi >/dev/null 2>&1 || return 0
  while IFS=, read -r pid mem; do
    pid="${pid//[[:space:]]/}"
    mem="${mem//[[:space:]]/}"
    [[ "$pid" =~ ^[0-9]+$ ]] || continue
    if is_owned_voice_model_pid "$pid"; then
      printf 'error: old JMCP voice/model PID still owns GPU memory pid=%s used_mb=%s\n' "$pid" "$mem" >&2
      failed=1
    fi
  done < <(nvidia-smi --query-compute-apps=pid,used_memory --format=csv,noheader,nounits 2>/dev/null || true)
  return "$failed"
}

owner_for_port() {
  local port="$1"
  ss -ltnp 2>/dev/null | awk -v port=":${port}" '$0 ~ port"[[:space:]]" {print; found=1} END {exit found ? 0 : 1}'
}

check_port_free() {
  local label="$1" port="$2" owner
  if owner="$(owner_for_port "$port")"; then
    printf 'error: %s port %s is occupied: %s\n' "$label" "$port" "$owner" >&2
    return 1
  fi
}

need_repo() {
  [[ -d "$1/.git" ]] || {
    printf 'error: missing split repo: %s\n' "$1" >&2
    return 1
  }
}

start_service() {
  local name="$1" cwd="$2" log="$3"
  shift 3
  printf 'starting %s log=%s\n' "$name" "$log"
  (cd "$cwd" && "$@") >"$log" 2>&1 &
  local pid=$!
  printf '%s\n' "$pid" >"$LIVE_ROOT/${name}.pid"
  PIDS+=("$pid")
  NAMES+=("$name")
}

wait_http() {
  local name="$1" url="$2" pid="$3" log="$4"
  local deadline=$((SECONDS + WAIT_SECONDS))
  while (( SECONDS < deadline )); do
    if curl -fsS --max-time 2 "$url" >/dev/null 2>&1; then
      printf '%s=ready url=%s\n' "$name" "$url"
      return 0
    fi
    if ! kill -0 "$pid" >/dev/null 2>&1; then
      tail -n 80 "$log" >&2 || true
      printf 'error: %s exited before %s became reachable\n' "$name" "$url" >&2
      return 1
    fi
    sleep 1
  done
  tail -n 80 "$log" >&2 || true
  printf 'error: %s did not become reachable at %s within %ss\n' "$name" "$url" "$WAIT_SECONDS" >&2
  return 1
}

stop_children() {
  local pid
  set +e
  for pid in "${PIDS[@]:-}"; do
    pkill -TERM -P "$pid" >/dev/null 2>&1 || true
    kill -TERM "$pid" >/dev/null 2>&1 || true
  done
  sleep 1
  for pid in "${PIDS[@]:-}"; do
    pkill -KILL -P "$pid" >/dev/null 2>&1 || true
    kill -KILL "$pid" >/dev/null 2>&1 || true
    wait "$pid" >/dev/null 2>&1 || true
  done
}

emit core "$CORE_REPO" "${core_cmd[@]}"
emit web "$WEB_REPO" "${web_cmd[@]}"
emit talk "$TALK_REPO" "${talk_cmd[@]}"
printf 'logs dir=%s\n' "$LOG_DIR"
printf 'routes cockpit=http://%s:%s jmcp=/jmcp voice=/voice voice_ws=/voice-ws voice_target=%s minicpm_debug=%s\n' \
  "$COCKPIT_HOST" "$COCKPIT_PORT" "$VOICE_TARGET" "$MINICPM_TARGET"

if [[ "$DRY_RUN" == "1" ]]; then
  exit 0
fi

need_repo "$CORE_REPO"
need_repo "$WEB_REPO"
need_repo "$TALK_REPO"

mkdir -p "$LOG_DIR" "$LIVE_ROOT"
cleanup_old_voice_models
gpu_memory_snapshot | tee "$LOG_DIR/gpu-memory-at-launch.log"
assert_no_old_gpu_voice_models
check_port_free "JMCP core" "$(port_from_bind "$CORE_BIND")"
check_port_free "cockpit" "$COCKPIT_PORT"
check_port_free "JMCP voice gateway" "$(port_from_url "$VOICE_TARGET")"

PIDS=()
NAMES=()
trap stop_children EXIT
trap 'exit 130' INT TERM

start_service core "$CORE_REPO" "$LOG_DIR/core.log" "${core_cmd[@]}"
wait_http core "$CORE_URL/health" "${PIDS[-1]}" "$LOG_DIR/core.log"

start_service talk "$TALK_REPO" "$LOG_DIR/voice.log" "${talk_cmd[@]}"
wait_http voice "$VOICE_TARGET/health" "${PIDS[-1]}" "$LOG_DIR/voice.log"

start_service web "$WEB_REPO" "$LOG_DIR/cockpit.log" "${web_cmd[@]}"
wait_http cockpit "http://$COCKPIT_HOST:$COCKPIT_PORT/" "${PIDS[-1]}" "$LOG_DIR/cockpit.log"
printf 'jmcp-live=ready cockpit=http://%s:%s core=%s voice=%s minicpm_debug=%s logs=%s\n' \
  "$COCKPIT_HOST" "$COCKPIT_PORT" "$CORE_URL" "$VOICE_TARGET" "$MINICPM_TARGET" "$LOG_DIR"

wait
