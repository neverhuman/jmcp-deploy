#!/usr/bin/env bash
# install-jankurai-hook.sh — install the jankurai pre-commit gate across repos (Cluster 4.2).
#   --repo NAME   install into one manifest repo (default: all onboarded)
#   --all         install into every manifest repo (default if no --repo)
#   --uninstall   remove the hook
# plain-git mode: symlinks hooks/jankurai-precommit.sh -> <repo>/.git/hooks/pre-commit. Git hooks are
# UNTRACKED (no jankurai generated-zone cap, no PR needed) — zero-friction, owner-gated by the env bypass.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; . "$HERE/lib.sh"; . "$HERE/manifest.sh"
HOOK="$HERE/hooks/jankurai-precommit.sh"
only=""; uninstall=0
while [[ $# -gt 0 ]]; do case "$1" in --repo) shift; only="${1:-}";; --all) :;; --uninstall) uninstall=1;; *) ;; esac; shift; done
n=0
while IFS='|' read -r name path gslug jslug; do
  [[ -n "$path" && -d "$path/.git" ]] || continue
  [[ -n "$only" && "$only" != "$name" ]] && continue
  dest="$path/.git/hooks/pre-commit"
  if [[ "$uninstall" == "1" ]]; then
    [[ -L "$dest" ]] && { rm -f "$dest"; say "removed jankurai hook from $name"; }
    continue
  fi
  if [[ -e "$dest" && ! -L "$dest" ]]; then warn "$name: existing non-symlink pre-commit hook — skipping (move it aside first)"; continue; fi
  ln -sf "$HOOK" "$dest"; n=$((n+1)); ok "installed jankurai pre-commit gate -> $name"
done < <(manifest_repos --rows 2>/dev/null)
[[ "$uninstall" == "1" ]] || ok "jankurai pre-commit gate installed in $n repo(s). Bypass any time with JANKURAI_SKIP_HOOKS=1."
