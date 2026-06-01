#!/usr/bin/env bash
set -Eeuo pipefail

score_guard_fail() {
  printf '[jankurai-hooks][error] %s\n' "$*" >&2
  exit 1
}

score_guard_load_counts() {
  local file="$1"
  jq -r '.rule_counts // {} | to_entries[] | [.key, .value] | @tsv' "$file"
}

score_guard_load_caps() {
  local file="$1"
  jq -r '.caps_applied[]?' "$file"
}

score_guard_compare() {
  local baseline="$1"
  local report="$2"
  local context="${3:-commit}"

  [[ -f "$baseline" ]] || score_guard_fail "missing score baseline: $baseline"
  [[ -f "$report" ]] || score_guard_fail "missing score report: $report"

  local baseline_score baseline_raw_score report_score report_raw_score
  baseline_score="$(jq -r '.score // 0' "$baseline")"
  baseline_raw_score="$(jq -r '.raw_score // .score // 0' "$baseline")"
  report_score="$(jq -r '.score // 0' "$report")"
  report_raw_score="$(jq -r '.raw_score // .score // 0' "$report")"

  [[ "$report_score" =~ ^-?[0-9]+$ ]] || score_guard_fail "invalid report score in $report"
  [[ "$report_raw_score" =~ ^-?[0-9]+$ ]] || score_guard_fail "invalid report raw score in $report"
  [[ "$baseline_score" =~ ^-?[0-9]+$ ]] || score_guard_fail "invalid baseline score in $baseline"
  [[ "$baseline_raw_score" =~ ^-?[0-9]+$ ]] || score_guard_fail "invalid baseline raw score in $baseline"

  if (( report_score < baseline_score )); then
    score_guard_fail "${context} score regressed: ${report_score} < ${baseline_score}"
  fi
  if (( report_raw_score < baseline_raw_score )); then
    score_guard_fail "${context} raw score regressed: ${report_raw_score} < ${baseline_raw_score}"
  fi

  declare -A baseline_rule_counts=()
  declare -A current_rule_counts=()
  declare -A baseline_caps=()

  while IFS=$'\t' read -r rule count; do
    [[ -n "$rule" ]] || continue
    baseline_rule_counts["$rule"]="$count"
  done < <(score_guard_load_counts "$baseline")

  while IFS=$'\t' read -r rule count; do
    [[ -n "$rule" ]] || continue
    current_rule_counts["$rule"]="$count"
    if [[ -z "${baseline_rule_counts[$rule]+x}" ]]; then
      score_guard_fail "${context} introduced new rule: ${rule}"
    fi
    if (( count > baseline_rule_counts["$rule"] )); then
      score_guard_fail "${context} increased rule count for ${rule}: ${count} > ${baseline_rule_counts[$rule]}"
    fi
  done < <(jq -r '.findings | group_by(.rule_id)[] | [.[0].rule_id, length] | @tsv' "$report")

  while IFS= read -r cap; do
    [[ -n "$cap" ]] || continue
    baseline_caps["$cap"]=1
  done < <(score_guard_load_caps "$baseline")

  while IFS= read -r cap; do
    [[ -n "$cap" ]] || continue
    if [[ -z "${baseline_caps[$cap]+x}" ]]; then
      score_guard_fail "${context} introduced new cap: ${cap}"
    fi
  done < <(score_guard_load_caps "$report")
}
