#!/usr/bin/env bash
# jeryu-ctl/host-ci.sh — the no-Docker native CI runner.
#
# jeryu's in-process bridge is hermetic (empty env, network-deny) and CANNOT build
# real Rust, so heavy CI runs HOST-NATIVE here (full toolchain, 40 workers, no Docker)
# and the result is posted to jeryu as the required check. jeryu stays the control
# plane (git/PR/checks/merge); the host is the runner — exactly the "like before" model,
# just driven by jeryu instead of GitHub.
#
# Usage: host-ci.sh <owner> <repo> <sha> <repo_path> [check_name]
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; . "$HERE/lib.sh"
OWNER="${1:?owner}"; REPO="${2:?repo}"; SHA="${3:?sha}"; REPO_PATH="${4:?repo_path}"
CHECK="${5:-jeryu/ci}"; ROOT=/home/ubuntu/jmcp-split
[[ -e "$REPO_PATH/.git" ]] || die "not a git repo: $REPO_PATH"
j_health || die "jeryu not healthy at $JERYU_BASE"

# Make sure the sha is present locally (it is if we pushed it; else fetch from jeryu).
git -C "$REPO_PATH" cat-file -e "$SHA^{commit}" 2>/dev/null || git -C "$REPO_PATH" fetch -q jeryu 2>/dev/null || true
git -C "$REPO_PATH" cat-file -e "$SHA^{commit}" 2>/dev/null || die "sha $SHA not found in $REPO_PATH"

tmp="$(mktemp -d)"
wt="$tmp/$REPO"
git -c filter.git-crypt.smudge=cat -c filter.git-crypt.required=false \
  -C "$REPO_PATH" worktree add -f --detach "$wt" "$SHA" >/dev/null 2>&1 \
  || { post_check "$OWNER" "$REPO" "$SHA" "$CHECK" failure; die "worktree checkout failed for $SHA"; }
cleanup(){
  git -C "$REPO_PATH" worktree remove -f "$wt" >/dev/null 2>&1 || true
  rmdir "$tmp" >/dev/null 2>&1 || true
}
trap cleanup EXIT

log="${JERYU_CTL_STATE}/${OWNER}__${REPO}/${SHA}.ci.log"; mkdir -p "$(dirname "$log")"

# --- SPEED: warm, shared compile caches so CI is incremental/cached across SHAs --------------
# The worktree is fresh per SHA (cold target/) and nothing used the installed sccache. Point the
# build at a PERSISTENT per-repo target dir + a SHARED sccache so unchanged crates never recompile.
# Serialized by the poll flock, so the per-repo target dir has a single writer. Opt-outs honored.
if [[ "${JERYU_CI_NO_TARGET_CACHE:-0}" != "1" && -z "${CARGO_TARGET_DIR:-}" ]]; then
  # opt-out per repo with JERYU_CI_NO_TARGET_CACHE=1 if a suite hardcodes ./target/debug paths
  export CARGO_TARGET_DIR="${JERYU_CI_CACHE:-/home/ubuntu/.cache/jeryu-ci}/${OWNER}__${REPO}/target"
  mkdir -p "$CARGO_TARGET_DIR"
fi
if [[ "${JERYU_CI_NO_SCCACHE:-0}" != "1" ]] && [[ -z "${RUSTC_WRAPPER:-}" ]] && command -v sccache >/dev/null 2>&1; then
  export RUSTC_WRAPPER="$(command -v sccache)"
  export SCCACHE_DIR="${JERYU_CI_CACHE:-/home/ubuntu/.cache/jeryu-ci}/sccache"
  export CARGO_INCREMENTAL=0   # sccache cannot cache incremental builds; disable so it caches whole crates
  mkdir -p "$SCCACHE_DIR"
fi

# CI-entrypoint cascade: pick the FIRST mechanism the repo actually provides and run
# exactly that (we do NOT keep trying until one passes — that would mask real failures).
# Split repos can provide ci-fast-push.sh; repos that lack it fall through to
# their own entrypoint so they still get a real jeryu/ci.
pick_and_run_ci() {   # cwd must be the worktree; logs chosen entrypoint; returns its rc
  if [[ -f ops/ci/pr-ci.sh ]]; then
    echo "[host-ci] entrypoint: bash ops/ci/pr-ci.sh"; bash ops/ci/pr-ci.sh; return $?
  fi
  if [[ -x ./ci-fast-push.sh ]]; then
    echo "[host-ci] entrypoint: ./ci-fast-push.sh --no-push --ci (WORKERS=${WORKERS:-40})"
    WORKERS="${WORKERS:-40}" ./ci-fast-push.sh --no-push --ci; return $?
  fi
  if [[ -f scripts/ci-local.sh ]]; then
    echo "[host-ci] entrypoint: bash scripts/ci-local.sh"; bash scripts/ci-local.sh; return $?
  fi
  if command -v just >/dev/null 2>&1 && [[ -f justfile || -f Justfile || -f .justfile ]] \
     && just --summary 2>/dev/null | tr ' ' '\n' | grep -qx check; then
    echo "[host-ci] entrypoint: just check"; just check; return $?
  fi
  if [[ -f Cargo.toml ]]; then
    if cargo nextest --version >/dev/null 2>&1; then
      echo "[host-ci] entrypoint: cargo nextest run --workspace"
      cargo nextest run --workspace --no-fail-fast; return $?
    fi
    echo "[host-ci] entrypoint: cargo test --workspace"
    cargo test --workspace --no-fail-fast; return $?
  fi
  echo "[host-ci] NO recognized CI entrypoint (ci-fast-push/pr-ci/ci-local/just check/Cargo.toml)"
  return 91
}

say "host-ci: $OWNER/$REPO@${SHA:0:12} (WORKERS=${WORKERS:-40}) in worktree"
if ( cd "$wt" && pick_and_run_ci ) >"$log" 2>&1; then
  post_check "$OWNER" "$REPO" "$SHA" "$CHECK" success
  ok "host-ci PASS -> posted $CHECK=success (log: $log)"
  echo success
else
  rc=$?
  post_check "$OWNER" "$REPO" "$SHA" "$CHECK" failure
  warn "host-ci FAIL (rc=$rc) -> posted $CHECK=failure (log: $log)"
  echo failure
fi
