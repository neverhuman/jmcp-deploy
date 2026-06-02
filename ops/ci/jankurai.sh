#!/usr/bin/env bash
set -Eeuo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

cd "$ROOT_DIR"

status=0

run_step() {
  local name="$1"
  shift

  log "$name"
  if ! "$@"; then
    warn "$name failed"
    status=1
  fi
}

run_step "jankurai: audit" \
  jankurai audit . \
    --mode advisory \
    --json target/jankurai/repo-score.json \
    --md target/jankurai/repo-score.md \
    --sarif target/jankurai/jankurai.sarif \
    --github-step-summary target/jankurai/summary.md \
    --repair-queue-jsonl target/jankurai/repair-queue.jsonl

run_step "jankurai: proof routing" \
  jankurai proof . \
    --changed-from origin/main \
    --out target/jankurai/proof-routing.json \
    --md target/jankurai/proof-routing.md

run_step "jankurai: regression ratchet" \
  bash ops/ci/jankurai-ratchet.sh

run_step "jankurai: proofbind verify" \
  jankurai proofbind verify . --changed-from origin/main

run_step "jankurai: proofmark rust" \
  jankurai proofmark rust . --obligations target/jankurai/proofbind/obligations.json

run_step "jankurai: copy-code" \
  jankurai copy-code . \
    --json target/jankurai/copy-code.json \
    --md target/jankurai/copy-code.md

run_step "jankurai: rust witness build" \
  jankurai rust witness build .

run_step "jankurai: security evidence" \
  jankurai security run \
    --script ops/ci/security.sh \
    --out target/jankurai/security/evidence.json

run_step "jankurai: language bad behavior evidence" \
  bash ops/ci/language-bad-behavior.sh

run_step "jankurai: contract drift" \
  bash ops/ci/contract-drift.sh

if [[ -f apps/web/package.json ]]; then
  run_step "jankurai: UX QA Playwright" \
    npm --prefix apps/web run test:ux
  run_step "jankurai: UX QA smoke" \
    jankurai ux audit --config agent/ux-qa.toml --out target/jankurai/ux-qa.json
else
  warn "jankurai: skipping UX QA smoke; apps/web/package.json not present"
fi

run_step "jankurai: cost budget" \
  bash ops/ci/cost-budget.sh

run_step "jankurai: release readiness" \
  bash ops/ci/release-readiness.sh

run_step "jankurai: agent tool supply receipt" \
  jankurai audit . \
    --mode advisory \
    --json target/jankurai/agent-tool-supply.json \
    --md target/jankurai/agent-tool-supply.md

exit "$status"
