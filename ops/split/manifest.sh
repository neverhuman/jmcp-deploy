#!/usr/bin/env bash
set -euo pipefail

manifest="repos.manifest.toml"
emit_json=0
required=(jmcp-core jmcp-web jmcp-talk jmcp-deploy)

usage() {
  printf 'usage: %s [--manifest PATH] [--json]\n' "$0" >&2
}

fail() {
  printf 'manifest error: %s\n' "$1" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --manifest)
      shift
      manifest="${1:-}"
      ;;
    --json)
      emit_json=1
      ;;
    *)
      usage
      exit 2
      ;;
  esac
  shift
done

[[ -n "$manifest" ]] || fail "--manifest requires a path"
[[ -r "$manifest" ]] || fail "manifest not readable: $manifest"

mapfile -t rows < <(
  awk '
    function trim(s) {
      gsub(/^[ \t\r\n]+|[ \t\r\n]+$/, "", s)
      return s
    }
    function unquote(s) {
      s = trim(s)
      if (s ~ /^".*"$/) {
        sub(/^"/, "", s)
        sub(/"$/, "", s)
      }
      return s
    }
    function flush() {
      if (!in_repo) return
      print name "|" path "|" github_slug "|" jeryu_slug "|" default_branch "|" has_jeryu_std "|" onboarded
    }
    /^\[\[repo\]\]/ {
      flush()
      in_repo = 1
      name = path = github_slug = jeryu_slug = default_branch = has_jeryu_std = onboarded = ""
      next
    }
    in_repo && /^[[:space:]]*[A-Za-z_]+[[:space:]]*=/ {
      line = $0
      sub(/[[:space:]]+#.*/, "", line)
      key = line
      sub(/[[:space:]]*=.*/, "", key)
      key = trim(key)
      val = line
      sub(/^[^=]*=/, "", val)
      val = unquote(val)
      if (key == "name") name = val
      else if (key == "path") path = val
      else if (key == "github_slug") github_slug = val
      else if (key == "jeryu_slug") jeryu_slug = val
      else if (key == "default_branch") default_branch = val
      else if (key == "has_jeryu_std") has_jeryu_std = val
      else if (key == "onboarded") onboarded = val
    }
    END { flush() }
  ' "$manifest"
)

[[ "${#rows[@]}" -gt 0 ]] || fail "manifest must contain [[repo]] entries"

declare -A seen=()
for row in "${rows[@]}"; do
  IFS='|' read -r name path github_slug jeryu_slug default_branch has_jeryu_std onboarded <<<"$row"
  [[ -n "$name" ]] || fail "repo entry missing name"
  seen["$name"]=1
  for field in path github_slug jeryu_slug default_branch; do
    value="${!field}"
    [[ -n "$value" ]] || fail "$name missing $field"
  done
  [[ "$has_jeryu_std" == "true" ]] || fail "$name must set has_jeryu_std=true"
  [[ "$onboarded" == "true" ]] || fail "$name must set onboarded=true"
done

missing=()
for name in "${required[@]}"; do
  [[ -n "${seen[$name]:-}" ]] || missing+=("$name")
done
if [[ "${#missing[@]}" -gt 0 ]]; then
  fail "manifest missing required repos: ${missing[*]}"
fi

if [[ "$emit_json" == "1" ]]; then
  printf '{\n  "repo": [\n'
  first=1
  for row in "${rows[@]}"; do
    IFS='|' read -r name path github_slug jeryu_slug default_branch has_jeryu_std onboarded <<<"$row"
    if [[ "$first" == "1" ]]; then
      first=0
    else
      printf ',\n'
    fi
    printf '    {"name": "%s", "path": "%s", "github_slug": "%s", "jeryu_slug": "%s", "default_branch": "%s", "has_jeryu_std": %s, "onboarded": %s}' \
      "$name" "$path" "$github_slug" "$jeryu_slug" "$default_branch" "$has_jeryu_std" "$onboarded"
  done
  printf '\n  ]\n}\n'
else
  for row in "${rows[@]}"; do
    IFS='|' read -r name path github_slug jeryu_slug _ <<<"$row"
    printf '%s|%s|%s|%s\n' "$name" "$path" "$github_slug" "$jeryu_slug"
  done
fi
