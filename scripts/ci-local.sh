#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMMAND="${1:-ci}"

case "$COMMAND" in
  fast)
    exec "${ROOT_DIR}/ops/ci/fast.sh"
    ;;
  ci)
    exec "${ROOT_DIR}/ops/ci/ci.sh"
    ;;
  security)
    exec "${ROOT_DIR}/ops/ci/security.sh"
    ;;
  conformance)
    exec "${ROOT_DIR}/ops/ci/conformance.sh"
    ;;
  jankurai-local)
    exec "${ROOT_DIR}/ops/ci/jankurai-local.sh"
    ;;
  doctor)
    exec "${ROOT_DIR}/scripts/ci-doctor.sh"
    ;;
  *)
    printf 'usage: %s [fast|ci|security|conformance|jankurai-local|doctor]\n' "$0" >&2
    exit 64
    ;;
esac
