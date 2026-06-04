#!/usr/bin/env bash
set -Eeuo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

cd "$ROOT_DIR"
mkdir -p target/jankurai .artifacts/db

mapfile -t migrations < <(find db/migrations -maxdepth 1 -type f -name '*.sql' | sort)
mapfile -t constraints < <(find db/constraints -maxdepth 1 -type f -name '*.sql' | sort)

if ((${#migrations[@]} == 0)); then
  fail "db-migration-analyze: no SQL migrations in db/migrations"
fi

for file in "${migrations[@]}" "${constraints[@]}"; do
  if [[ ! -s "$file" ]]; then
    fail "db-migration-analyze: empty SQL truth file: $file"
  fi
done

json_escape() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//$'\n'/\\n}"
  value="${value//$'\r'/\\r}"
  value="${value//$'\t'/\\t}"
  printf '%s' "$value"
}

json_array() {
  local first=1
  printf '['
  for item in "$@"; do
    if ((first)); then
      first=0
    else
      printf ','
    fi
    printf '"%s"' "$(json_escape "$item")"
  done
  printf ']'
}

log "db-migration-analyze: running jmcp-store migration tests"
set +e
cargo test -p jmcp-store migration --locked >.artifacts/db/migration-tests.log 2>&1
test_status=$?
set -e

status="passed"
if ((test_status != 0)); then
  status="failed"
fi

{
  printf '{\n'
  printf '  "schema_version": 1,\n'
  printf '  "lane": "db-migration-analyze",\n'
  printf '  "status": "%s",\n' "$status"
  printf '  "generated_at": "%s",\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  printf '  "git_head": "%s",\n' "$(git rev-parse --verify HEAD)"
  printf '  "migration_count": %s,\n' "${#migrations[@]}"
  printf '  "constraint_count": %s,\n' "${#constraints[@]}"
  printf '  "migrations": '
  json_array "${migrations[@]}"
  printf ',\n'
  printf '  "constraints": '
  json_array "${constraints[@]}"
  printf ',\n'
  printf '  "commands": [\n'
  printf '    {\n'
  printf '      "name": "jmcp-store migration tests",\n'
  printf '      "command": "cargo test -p jmcp-store migration --locked",\n'
  printf '      "exit_code": %s,\n' "$test_status"
  printf '      "log_path": ".artifacts/db/migration-tests.log"\n'
  printf '    }\n'
  printf '  ]\n'
  printf '}\n'
} >target/jankurai/migration-report.json

if ((test_status != 0)); then
  warn "db-migration-analyze: jmcp-store migration tests failed"
  tail -n 80 .artifacts/db/migration-tests.log >&2 || true
  exit "$test_status"
fi

log "db-migration-analyze: wrote target/jankurai/migration-report.json"
