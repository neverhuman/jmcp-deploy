#!/usr/bin/env bash
set -Eeuo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

cd "$ROOT_DIR"
mkdir -p .artifacts/security target/jankurai/security

evidence_out="${JMCP_SECURITY_EVIDENCE_OUT:-target/jankurai/security/evidence.json}"
commands_json="$(mktemp)"
first_command=1
passed_count=0
failed_count=0
missing_count=0
skipped_count=0
overall_status=0

json_escape() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//$'\n'/\\n}"
  value="${value//$'\r'/\\r}"
  value="${value//$'\t'/\\t}"
  printf '%s' "$value"
}

append_command() {
  local name="$1"
  local tool="$2"
  local command="$3"
  local status="$4"
  local exit_code="$5"
  local log_path="$6"
  local reason="${7:-}"

  case "$status" in
    passed) passed_count=$((passed_count + 1)) ;;
    failed)
      failed_count=$((failed_count + 1))
      overall_status=1
      ;;
    missing)
      missing_count=$((missing_count + 1))
      [[ "$STRICT_TOOLS" == "1" ]] && overall_status=1
      ;;
    skipped) skipped_count=$((skipped_count + 1)) ;;
  esac

  if ((first_command)); then
    first_command=0
  else
    printf ',\n' >>"$commands_json"
  fi

  {
    printf '    {\n'
    printf '      "name": "%s",\n' "$(json_escape "$name")"
    printf '      "tool": "%s",\n' "$(json_escape "$tool")"
    printf '      "command": "%s",\n' "$(json_escape "$command")"
    printf '      "status": "%s",\n' "$status"
    if [[ -n "$exit_code" ]]; then
      printf '      "exit_code": %s,\n' "$exit_code"
    else
      printf '      "exit_code": null,\n'
    fi
    printf '      "log_path": "%s",\n' "$(json_escape "$log_path")"
    printf '      "reason": "%s"\n' "$(json_escape "$reason")"
    printf '    }'
  } >>"$commands_json"
}

record_missing() {
  local name="$1"
  local tool="$2"
  local command="$3"
  local reason="$4"

  if [[ "$STRICT_TOOLS" == "1" ]]; then
    warn "missing ${tool}: ${reason}; strict mode will fail after evidence is written"
  else
    missing_tool "$tool" "$reason"
  fi
  append_command "$name" "$tool" "$command" "missing" "" "" "$reason"
}

record_skipped() {
  append_command "$1" "$2" "$3" "skipped" "" "" "$4"
  warn "skipping $1: $4"
}

run_scan() {
  local name="$1"
  local tool="$2"
  local command_label="$3"
  local log_path="$4"
  shift 4

  if ! has "$tool"; then
    record_missing "$name" "$tool" "$command_label" "$name"
    return 0
  fi

  log "security: running $name"
  set +e
  "$@" >"$log_path" 2>&1
  local status=$?
  set -e

  if ((status == 0)); then
    append_command "$name" "$tool" "$command_label" "passed" "$status" "$log_path"
  else
    append_command "$name" "$tool" "$command_label" "failed" "$status" "$log_path"
    warn "security: $name failed; see $log_path"
  fi
}

write_evidence() {
  {
    printf '{\n'
    printf '  "schema_version": 1,\n'
    printf '  "lane": "security",\n'
    printf '  "repo_root": "%s",\n' "$(json_escape "$ROOT_DIR")"
    printf '  "generated_at": "%s",\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    printf '  "git_head": "%s",\n' "$(git rev-parse --verify HEAD)"
    printf '  "policy": "missing tools warn unless JMCP_STRICT_TOOLS=1",\n'
    printf '  "summary": {\n'
    printf '    "passed": %s,\n' "$passed_count"
    printf '    "failed": %s,\n' "$failed_count"
    printf '    "missing": %s,\n' "$missing_count"
    printf '    "skipped": %s\n' "$skipped_count"
    printf '  },\n'
    printf '  "commands": [\n'
    cat "$commands_json"
    printf '\n  ]\n'
    printf '}\n'
  } >"$evidence_out"
}

cleanup() {
  rm -f "$commands_json"
}
trap cleanup EXIT

run_scan \
  "gitleaks" \
  "gitleaks" \
  "gitleaks detect --source . --config gitleaks.toml --no-banner --redact --no-git" \
  ".artifacts/security/gitleaks.log" \
  gitleaks detect --source . --config gitleaks.toml --no-banner --redact --no-git

if repo_has Cargo.lock; then
  run_scan \
    "cargo audit" \
    "cargo-audit" \
    "cargo audit --ignore RUSTSEC-2024-0436 --ignore RUSTSEC-2026-0002" \
    ".artifacts/security/cargo-audit.log" \
    cargo audit --ignore RUSTSEC-2024-0436 --ignore RUSTSEC-2026-0002
elif repo_has Cargo.toml; then
  record_skipped "cargo audit" "cargo-audit" "cargo audit" "Cargo.lock not present"
else
  record_skipped "cargo audit" "cargo-audit" "cargo audit" "Cargo workspace not present"
fi

if repo_has Cargo.toml && ! has cargo; then
  record_missing "cargo deny" "cargo" "cargo deny check" "Rust dependency policy"
elif cargo_workspace_ready; then
  run_scan \
    "cargo deny" \
    "cargo-deny" \
    "cargo deny check" \
    ".artifacts/security/cargo-deny.log" \
    cargo deny check
elif repo_has Cargo.toml; then
  record_skipped "cargo deny" "cargo-deny" "cargo deny check" "Cargo workspace metadata is not ready"
else
  record_skipped "cargo deny" "cargo-deny" "cargo deny check" "Cargo workspace not present"
fi

if repo_has package-lock.json && has npm; then
  run_scan \
    "npm audit" \
    "npm" \
    "npm audit --audit-level=high" \
    ".artifacts/security/npm-audit.log" \
    npm audit --audit-level=high
elif repo_has package-lock.json; then
  record_missing "npm audit" "npm" "npm audit --audit-level=high" "npm advisory scanning"
else
  record_skipped "npm audit" "npm" "npm audit --audit-level=high" "package-lock.json not present"
fi

run_scan \
  "zizmor" \
  "zizmor" \
  "zizmor .github/workflows" \
  ".artifacts/security/zizmor.log" \
  zizmor .github/workflows

run_scan \
  "syft" \
  "syft" \
  "syft dir:. -o spdx-json=.artifacts/security/jmcp.spdx.json" \
  ".artifacts/security/syft.log" \
  syft dir:. -o spdx-json=.artifacts/security/jmcp.spdx.json

run_scan \
  "actionlint" \
  "actionlint" \
  "actionlint" \
  ".artifacts/security/actionlint.log" \
  actionlint

write_evidence
log "security: complete"
exit "$overall_status"
