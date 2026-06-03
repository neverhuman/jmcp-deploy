#!/usr/bin/env bash
set -Eeuo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

cd "$ROOT_DIR"

remote="${JMCP_PUBLISH_REMOTE:-github}"
branch="${JMCP_PUBLISH_BRANCH:-main}"

log "publish-main: validating local CI gates"
"${ROOT_DIR}/ops/ci/ci.sh"
"${ROOT_DIR}/ops/ci/conformance.sh"

if [[ -n "$(git status --porcelain)" ]]; then
  fail "publish-main requires a clean worktree"
fi

current_branch="$(git symbolic-ref --quiet --short HEAD || true)"
if [[ "$current_branch" != "$branch" ]]; then
  fail "publish-main must run from ${branch}; current branch is ${current_branch:-detached}"
fi

log "publish-main: fetching ${remote}/${branch}"
git fetch "$remote" "$branch" --prune

base_ref="${remote}/${branch}"
if ! git merge-base --is-ancestor "$base_ref" HEAD; then
  fail "current ${branch} does not contain ${base_ref}; integrate the remote tip first"
fi

merge_count="$(git rev-list --merges "${base_ref}..HEAD" | wc -l | tr -d ' ')"
if [[ "${merge_count}" != "0" ]]; then
  fail "merge commits detected in ${branch} since ${base_ref}; remote ${remote} rejects merge commits, so rebase or squash before publishing"
fi

log "publish-main: pushing ${branch} to ${remote}"
git push "$remote" "HEAD:${branch}"
log "publish-main: complete"
