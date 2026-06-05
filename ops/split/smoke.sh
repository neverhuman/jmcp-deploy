#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="${JMCP_SPLIT_ROOT:-/home/ubuntu/jmcp-split}"
DEPLOY_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CORE_REPO="${JMCP_CORE_REPO:-$ROOT/jmcp-core}"
WEB_REPO="${JMCP_WEB_REPO:-$ROOT/jmcp-web}"
TALK_REPO="${JMCP_TALK_REPO:-$ROOT/jmcp-talk}"
WAIT_SECONDS="${SPLIT_SMOKE_WAIT_SECONDS:-120}"
KEEP_ARTIFACTS="${SPLIT_SMOKE_KEEP_ARTIFACTS:-0}"

mkdir -p "$DEPLOY_REPO/target"
RUN_DIR="${SPLIT_SMOKE_RUN_DIR:-$(mktemp -d "$DEPLOY_REPO/target/split-smoke.XXXXXX")}"
PIDS=()
LOGS=()

cleanup() {
  local status=$?
  set +e
  for pid in "${PIDS[@]}"; do
    pkill -TERM -P "$pid" >/dev/null 2>&1 || true
    kill -TERM "$pid" >/dev/null 2>&1 || true
  done
  sleep 1
  for pid in "${PIDS[@]}"; do
    pkill -KILL -P "$pid" >/dev/null 2>&1 || true
    kill -KILL "$pid" >/dev/null 2>&1 || true
    wait "$pid" >/dev/null 2>&1 || true
  done
  if [[ "$status" == "0" && "$KEEP_ARTIFACTS" != "1" ]]; then
    rm -rf "$RUN_DIR"
  else
    printf 'split-smoke artifacts=%s\n' "$RUN_DIR" >&2
  fi
}
trap cleanup EXIT
trap 'exit 130' INT TERM

fail() {
  printf 'split-smoke: %s\n' "$*" >&2
  exit 1
}

step() {
  printf '[split-smoke] %s\n' "$*"
}

need_dir() {
  [[ -d "$1/.git" ]] || fail "missing git repo: $1"
}

pick_port() {
  python3 - <<'PY'
import socket
sock = socket.socket()
sock.bind(("127.0.0.1", 0))
print(sock.getsockname()[1])
sock.close()
PY
}

cargo_target_dir() {
  (cd "$1" && cargo metadata --format-version 1 --no-deps) \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["target_directory"])'
}

start_service() {
  local name="$1" cwd="$2" log="$3"
  shift 3
  step "starting $name"
  (cd "$cwd" && "$@") >"$log" 2>&1 &
  local pid=$!
  PIDS+=("$pid")
  LOGS+=("$log")
  printf '[split-smoke] %s pid=%s log=%s\n' "$name" "$pid" "$log"
}

wait_http() {
  local name="$1" url="$2" pid="$3" log="$4"
  local deadline=$((SECONDS + WAIT_SECONDS))
  while (( SECONDS < deadline )); do
    if curl -fsS --max-time 2 "$url" >/dev/null 2>&1; then
      return 0
    fi
    if ! kill -0 "$pid" >/dev/null 2>&1; then
      tail -n 80 "$log" >&2 || true
      fail "$name exited before $url became reachable"
    fi
    sleep 1
  done
  tail -n 80 "$log" >&2 || true
  fail "$name did not become reachable at $url within ${WAIT_SECONDS}s"
}

fetch() {
  local label="$1" url="$2" out="$3"
  curl -fsS --max-time 10 "$url" -o "$out" || fail "request failed: $label $url"
}

assert_core_health() {
  python3 - "$1" <<'PY'
import json
import sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
assert data.get("ok") is True, data
assert data.get("system") == "JMCP", data
PY
}

assert_core_runtime() {
  python3 - "$1" <<'PY'
import json
import sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
assert data.get("system") == "JMCP", data
assert data.get("protocol") == "JCP/1.0.0", data
assert data.get("transportProfile") == "JPCM", data
authority = data.get("authority") or {}
assert authority.get("approvals") == "jmcp-core", data
PY
}

assert_core_contract() {
  local headers="$1" body="$2"
  grep -qi '^x-jmcp-contract:' "$headers" || fail "contract response missing X-JMCP-Contract header"
  python3 - "$body" <<'PY'
import json
import sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
assert data.get("system") == "JMCP", data
assert data.get("protocol") == "JCP/1.0.0", data
assert "/health" in data.get("routes", []), data
assert "/runtime" in data.get("routes", []), data
assert "/contract" in data.get("routes", []), data
PY
}

assert_talk_health() {
  python3 - "$1" <<'PY'
import json
import sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
assert data.get("ok") is True, data
assert data.get("adapter") == "deterministic", data
assert data.get("loaded") is True, data
assert data.get("raw_audio_capture") is False, data
PY
}

assert_transcript() {
  python3 - "$1" "$2" <<'PY'
import json
import sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
assert data.get("text") == sys.argv[2], data
assert data.get("language") == "en", data
assert data.get("confidence") == 1.0, data
PY
}

assert_wav() {
  python3 - "$1" <<'PY'
import sys
data = open(sys.argv[1], "rb").read()
assert data.startswith(b"RIFF"), data[:16]
assert b"split smoke synthesis" in data, data[:80]
PY
}

need_dir "$CORE_REPO"
need_dir "$WEB_REPO"
need_dir "$TALK_REPO"

core_port="$(pick_port)"
web_port="$(pick_port)"
talk_port="$(pick_port)"
core_url="http://127.0.0.1:${core_port}"
web_url="http://127.0.0.1:${web_port}"
talk_url="http://127.0.0.1:${talk_port}"
transcript="split smoke deterministic transcript"

step "building core jmcpd"
(cd "$CORE_REPO" && cargo build --locked -p jmcpd)
core_bin="$(cargo_target_dir "$CORE_REPO")/debug/jmcpd"
[[ -x "$core_bin" ]] || fail "missing core binary: $core_bin"

step "building cockpit"
(
  cd "$WEB_REPO"
  VITE_JMCP_API_URL="$core_url" \
    VITE_JMCP_BASE="/jmcp" \
    VITE_ASR_BASE="/asr" \
    VITE_TTS_BASE="/tts" \
    VITE_LLM_BASE="/llm" \
    npm --workspace @jmcp/cockpit run build
)
[[ -f "$WEB_REPO/apps/cockpit/dist/index.html" ]] || fail "cockpit build did not produce dist/index.html"

step "building deterministic speech daemon"
(cd "$TALK_REPO" && cargo build --locked -p jmcp-speechd)
talk_bin="$(cargo_target_dir "$TALK_REPO")/debug/jmcp-speechd"
[[ -x "$talk_bin" ]] || fail "missing talk binary: $talk_bin"

start_service \
  core "$CORE_REPO" "$RUN_DIR/core.log" \
  env RUST_LOG=warn "$core_bin" \
    --listen "127.0.0.1:${core_port}" \
    --database "$RUN_DIR/jmcp-smoke.sqlite"
wait_http core "$core_url/health" "${PIDS[-1]}" "${LOGS[-1]}"

start_service \
  talk "$TALK_REPO" "$RUN_DIR/talk.log" \
  env JMCP_TALK_BIND="127.0.0.1:${talk_port}" \
    JMCP_TALK_TRACE_PATH="$RUN_DIR/speech-trace.jsonl" \
    JMCP_TALK_DETERMINISTIC_TRANSCRIPT="$transcript" \
    "$talk_bin"
wait_http talk "$talk_url/health" "${PIDS[-1]}" "${LOGS[-1]}"

start_service \
  cockpit "$WEB_REPO" "$RUN_DIR/cockpit.log" \
  env JMCP_COCKPIT_HOST=127.0.0.1 \
    JMCP_COCKPIT_PORT="$web_port" \
    VITE_JMCP_TARGET="$core_url" \
    VITE_ASR_TARGET="$talk_url" \
    VITE_TTS_TARGET="$talk_url" \
    VITE_LLM_TARGET="http://127.0.0.1:18902" \
    VITE_JMCP_API_URL="$core_url" \
    VITE_JMCP_BASE="/jmcp" \
    VITE_ASR_BASE="/asr" \
    VITE_TTS_BASE="/tts" \
    VITE_LLM_BASE="/llm" \
    npm --workspace @jmcp/cockpit run dev -- --host 127.0.0.1 --port "$web_port"
wait_http cockpit "$web_url/" "${PIDS[-1]}" "${LOGS[-1]}"

step "verifying core endpoints"
fetch core-health "$core_url/health" "$RUN_DIR/core-health.json"
assert_core_health "$RUN_DIR/core-health.json"
fetch core-runtime "$core_url/runtime" "$RUN_DIR/core-runtime.json"
assert_core_runtime "$RUN_DIR/core-runtime.json"
curl -fsS --max-time 10 -D "$RUN_DIR/core-contract.headers" "$core_url/contract" \
  -o "$RUN_DIR/core-contract.json" || fail "request failed: core contract"
assert_core_contract "$RUN_DIR/core-contract.headers" "$RUN_DIR/core-contract.json"

step "verifying cockpit HTML"
fetch cockpit-html "$web_url/" "$RUN_DIR/cockpit.html"
grep -q '<div id="root"' "$RUN_DIR/cockpit.html" || fail "cockpit HTML missing root mount"
grep -q 'type="module"' "$RUN_DIR/cockpit.html" || fail "cockpit HTML missing module script"
fetch cockpit-jmcp-proxy "$web_url/jmcp/health" "$RUN_DIR/cockpit-jmcp-health.json"
assert_core_health "$RUN_DIR/cockpit-jmcp-health.json"
fetch cockpit-asr-proxy "$web_url/asr/health" "$RUN_DIR/cockpit-asr-health.json"
assert_talk_health "$RUN_DIR/cockpit-asr-health.json"
fetch cockpit-tts-proxy "$web_url/tts/health" "$RUN_DIR/cockpit-tts-health.json"
assert_talk_health "$RUN_DIR/cockpit-tts-health.json"

step "verifying talk endpoints"
fetch talk-health "$talk_url/health" "$RUN_DIR/talk-health.json"
assert_talk_health "$RUN_DIR/talk-health.json"
fetch talk-metrics-before "$talk_url/metrics" "$RUN_DIR/talk-metrics-before.txt"
grep -q 'jmcp_talk_requests_total{route="/health"}' "$RUN_DIR/talk-metrics-before.txt" \
  || fail "talk metrics missing health counter"
printf 'not real audio; deterministic handler hashes bytes only' \
  | curl -fsS --max-time 10 -X POST --data-binary @- "$talk_url/transcribe" \
      -o "$RUN_DIR/talk-transcribe.json" \
  || fail "request failed: talk transcribe"
assert_transcript "$RUN_DIR/talk-transcribe.json" "$transcript"
curl -fsS --max-time 10 -X POST "$talk_url/synthesize" \
  -H 'content-type: application/json' \
  -d '{"text":"split smoke synthesis","voice":"fixture","speed":1.0}' \
  -o "$RUN_DIR/talk-synthesize.wav" \
  || fail "request failed: talk synthesize"
assert_wav "$RUN_DIR/talk-synthesize.wav"
fetch talk-metrics-after "$talk_url/metrics" "$RUN_DIR/talk-metrics-after.txt"
grep -q 'jmcp_talk_requests_total{route="/transcribe"} 1' "$RUN_DIR/talk-metrics-after.txt" \
  || fail "talk metrics missing transcribe count"
grep -q 'jmcp_talk_requests_total{route="/synthesize"} 1' "$RUN_DIR/talk-metrics-after.txt" \
  || fail "talk metrics missing synthesize count"

printf 'split-smoke=ok core=%s cockpit=%s talk=%s\n' "$core_url" "$web_url" "$talk_url"
