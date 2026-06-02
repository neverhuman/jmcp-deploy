#!/usr/bin/env bash
set -Eeuo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

cd "$ROOT_DIR"
mkdir -p target/jankurai

log "language-bad-behavior: recording CI/git/release scan receipt"
{
  printf 'ci-bad-behavior: zizmor .github/workflows\n'
  printf 'git-bad-behavior: ops/git-hooks/score-guard.sh and jankurai-ratchet.sh\n'
  printf 'release-bad-behavior: docs/release.md and ops/ci/release-readiness.sh\n'
} > target/jankurai/language-bad-behavior.log

log "language-bad-behavior: complete"
