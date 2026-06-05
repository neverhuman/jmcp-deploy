#!/usr/bin/env bash
# jeryu-ctl/mirror-to-github-main.sh — best-effort GitHub main mirror.
#
# Jeryu is authoritative. This script mirrors a locally gated Jeryu main commit
# to GitHub main only after the local Jeryu checks are green. GitHub failures are
# reported as informational check-runs and never feed back into the green gate.
#
# Usage:
#   mirror-to-github-main.sh <jeryu_owner> <repo> <jeryu_sha> <github_slug> [--dry-run]
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; . "$HERE/lib.sh"

OWNER="${1:?jeryu_owner}"; REPO="${2:?repo}"; SHA="${3:?jeryu_sha}"; SLUG="${4:?github_slug}"; shift 4
DRY_RUN=0
while [[ $# -gt 0 ]]; do case "$1" in
  --dry-run) DRY_RUN=1;;
  *) die "unknown arg: $1";;
esac; shift; done

CHECK="jeryu/github-mirror"
bare="$(bare_path "$OWNER" "$REPO")"; [[ -d "$bare" ]] || die "no bare repo: $bare"
git -C "$bare" cat-file -e "$SHA^{commit}" 2>/dev/null || die "$OWNER/$REPO: no commit $SHA in $bare"

check_required() {
  local name="$1"
  [[ "$(check_conclusion "$OWNER" "$REPO" "$SHA" "$name")" == "success" ]]
}

neutral() {
  warn "$OWNER/$REPO@${SHA:0:12}: github mirror skipped: $*"
  [[ "$DRY_RUN" == "1" ]] || post_check "$OWNER" "$REPO" "$SHA" "$CHECK" neutral || true
}

success() {
  ok "$OWNER/$REPO@${SHA:0:12}: github mirror success: $*"
  [[ "$DRY_RUN" == "1" ]] || post_check "$OWNER" "$REPO" "$SHA" "$CHECK" success || true
}

for required in jeryu/ci jeryu/agent-review jeryu/release; do
  if ! check_required "$required"; then
    neutral "$required is not success"
    exit 0
  fi
done

guard_no_insteadof
ssh_host="${JERYU_GITHUB_SSH_HOST:-github-neverhuman}"
ssh_url="${ssh_host}:${SLUG}.git"
url=""
auth_label=""
if git -C "$bare" ls-remote -q "$ssh_url" refs/heads/main >/dev/null 2>&1; then
  url="$ssh_url"
  auth_label="ssh"
else
  tok="$(github_token)"
  [[ -n "$tok" ]] || { neutral "no github ssh access and no github token"; exit 0; }
  url="https://x-access-token:${tok}@github.com/${SLUG}.git"
  auth_label="https-token"
fi

if ! git -C "$bare" fetch -q --no-tags "$url" +refs/heads/main:refs/jeryu-mirror/github-main 2>/dev/null; then
  neutral "could not fetch github main for $SLUG via $auth_label"
  exit 0
fi

gh_main="$(git -C "$bare" rev-parse --verify refs/jeryu-mirror/github-main 2>/dev/null)" || {
  neutral "github main ref missing after fetch"
  exit 0
}
jeryu_tree="$(git -C "$bare" show -s --format=%T "$SHA")"
gh_tree="$(git -C "$bare" show -s --format=%T "$gh_main")"

if [[ "$gh_main" == "$SHA" ]]; then
  success "github main already points at the exact Jeryu commit"
  exit 0
fi

if [[ "$gh_tree" == "$jeryu_tree" ]]; then
  success "github main already has the Jeryu tree"
  exit 0
fi

if git -C "$bare" merge-base --is-ancestor "$gh_main" "$SHA" 2>/dev/null; then
  say "$OWNER/$REPO@${SHA:0:12}: exact fast-forward possible on $SLUG (${gh_main:0:12} -> ${SHA:0:12})"
  if [[ "$DRY_RUN" == "1" ]]; then
    exit 0
  fi
  push_out="$(git -C "$bare" push "$url" "$SHA:refs/heads/main" 2>&1)"
  push_rc=$?
  printf '%s\n' "$push_out" | grep -vi 'x-access-token' | tail -5 >&2 || true
  if [[ "$push_rc" -eq 0 ]]; then
    success "pushed exact Jeryu commit to github main"
  else
    neutral "exact fast-forward push failed"
  fi
  exit 0
fi

say "$OWNER/$REPO@${SHA:0:12}: wrapper commit required on $SLUG (github main ${gh_main:0:12} is not an ancestor)"
if [[ "$DRY_RUN" == "1" ]]; then
  exit 0
fi

wrapper="$(
  GIT_AUTHOR_NAME="jeryu mirror" \
  GIT_AUTHOR_EMAIL="jeryu-mirror@localhost" \
  GIT_COMMITTER_NAME="jeryu mirror" \
  GIT_COMMITTER_EMAIL="jeryu-mirror@localhost" \
  git -C "$bare" commit-tree "$jeryu_tree" -p "$gh_main" <<EOF
Jeryu mirror: ${SHA:0:12}

Mirror the locally gated Jeryu main commit to GitHub main.

Jeryu-Commit: $SHA
EOF
)" || { neutral "could not create wrapper commit"; exit 0; }

push_out="$(git -C "$bare" push "$url" "$wrapper:refs/heads/main" 2>&1)"
push_rc=$?
printf '%s\n' "$push_out" | grep -vi 'x-access-token' | tail -5 >&2 || true
if [[ "$push_rc" -eq 0 ]]; then
  success "pushed wrapper commit ${wrapper:0:12} to github main"
else
  neutral "wrapper fast-forward push failed"
fi
