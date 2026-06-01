#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
dry_run=0

if [[ "${1:-}" == "--dry-run" ]]; then
  dry_run=1
fi

is_under_repo() {
  local path="$1"
  [[ "$path" == "$repo_root" || "$path" == "$repo_root/"* ]]
}

is_under_cockpit() {
  local path="$1"
  [[ "$path" == "$repo_root/apps/cockpit" || "$path" == "$repo_root/apps/cockpit/"* ]]
}

is_jmcp_root_process() {
  local pid="$1"
  local comm="$2"
  local args="$3"
  local cwd=""
  local exe=""

  cwd="$(readlink -f "/proc/${pid}/cwd" 2>/dev/null || true)"
  exe="$(readlink -f "/proc/${pid}/exe" 2>/dev/null || true)"

  case "$args" in
    *"$repo_root/target/"*"/jmcpd"*|*"$repo_root/apps/jmcpd"*)
      { is_under_repo "$cwd" || is_under_repo "$exe"; } && return 0
      ;;
    *"npm --workspace @jmcp/cockpit run dev"*)
      is_under_repo "$cwd" && return 0
      ;;
    *"npm run dev"*)
      is_under_cockpit "$cwd" && return 0
      ;;
    *"sh -c vite"*|*"node $repo_root/node_modules/.bin/vite"*)
      is_under_cockpit "$cwd" && return 0
      ;;
  esac

  return 1
}

declare -A ppid_by_pid=()
declare -A candidate_by_pid=()

while read -r pid ppid comm args; do
  [[ -z "${pid:-}" ]] && continue
  ppid_by_pid["$pid"]="$ppid"
  if [[ "$pid" != "$$" ]] && is_jmcp_root_process "$pid" "$comm" "$args"; then
    candidate_by_pid["$pid"]=1
  fi
done < <(ps -eo pid=,ppid=,comm=,args=)

changed=1
while [[ "$changed" -eq 1 ]]; do
  changed=0
  for pid in "${!ppid_by_pid[@]}"; do
    [[ -z "${pid:-}" ]] && continue
    if [[ -n "${candidate_by_pid[$pid]:-}" ]]; then
      continue
    fi
    parent="${ppid_by_pid[$pid]}"
    if [[ -n "${candidate_by_pid[$parent]:-}" ]]; then
      candidate_by_pid["$pid"]=1
      changed=1
    fi
  done
done

if [[ "${#candidate_by_pid[@]}" -eq 0 ]]; then
  candidates=()
else
  mapfile -t candidates < <(printf '%s\n' "${!candidate_by_pid[@]}" | sort -n)
fi

if [[ "${#candidates[@]}" -eq 0 ]]; then
  printf 'No JMCP-owned dev processes found.\n'
  exit 0
fi

printf 'JMCP-owned dev processes:\n'
for pid in "${candidates[@]}"; do
  ps -o pid=,ppid=,pgid=,comm=,args= -p "$pid"
done

if [[ "$dry_run" -eq 1 ]]; then
  printf 'Dry run only; no processes stopped.\n'
  exit 0
fi

kill -TERM "${candidates[@]}" 2>/dev/null || true
sleep 1

remaining=()
for pid in "${candidates[@]}"; do
  if kill -0 "$pid" 2>/dev/null; then
    remaining+=("$pid")
  fi
done

if [[ "${#remaining[@]}" -gt 0 ]]; then
  kill -KILL "${remaining[@]}" 2>/dev/null || true
fi

printf 'Stopped %s JMCP-owned dev process(es).\n' "${#candidates[@]}"
