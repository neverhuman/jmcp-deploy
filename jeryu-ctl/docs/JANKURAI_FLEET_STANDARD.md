# Jankurai Fleet Standard — canonical adoption (Cluster 4.3)

How a repo joins the jankurai-audited fleet, how the system-wide view + pre-commit gate work, and the
canonical landing model. The *rule* definitions live in the jankurai engine (`~/jankurai`, Codex's lane);
this doc is the host-side adoption guide (jeryu-ctl, my lane).

## A repo adopts the standard by carrying
- `agent/JANKURAI_STANDARD.md` — the standard the repo conforms to.
- `agent/tool-adoption.toml` — the tools the repo should use (each with `ci_command` + `artifact_paths`);
  the auditor scores adoption by looking for that CI evidence.
- `agent/audit-policy.toml` — `minimum_score = 85`, `cap_overrides`, scan exclusions.
- `ops/ci/jankurai.sh` — the CI lane (see `jankurai-ci-template.md`); writes `.jankurai/repo-score.json`.
A repo with a fresh `.jankurai/repo-score.json` shows up `fresh` on the fleet board.

## System-wide view (which repos fail jankurai)
- `jeryu-ctl/jankurai-fleet.sh [--mode cached|full]` aggregates every manifest repo's score into the exact
  `FleetBoardPayload` and writes `~/.jankurai/fleet-board.json` — which **JMCP `/fleet-board` already reads**.
  `--mode cached` uses each repo's `.jankurai/repo-score.json`; `--mode full` runs `jankurai score` for
  uncached repos into a TEMP path (never mutates the repo → no generated-zone cap). `jankurai-fleet.timer`
  refreshes hourly (`--mode full`).
- `jeryu-ctl/jankurai-waste.sh` reports redundant-LOC + tool-adoption gaps (informational; propose a
  `HLT-WASTE` engine cap to Codex from the rollup).

## Pre-commit score gate
- `jeryu-ctl/install-jankurai-hook.sh [--all|--repo R|--uninstall]` symlinks `hooks/jankurai-precommit.sh`
  into `.git/hooks/pre-commit` (untracked → no cap, no PR). It runs `jankurai diff-audit` (diff-scoped, ~5s
  warm) and BLOCKS only commits that introduce **new** hard findings or caps; cold/slow repos degrade to
  advisory past `JANKURAI_HOOK_TIMEOUT` (60s). Bypass: `JANKURAI_SKIP_HOOKS=1` or `git commit --no-verify`.

## Canonical landing model (do NOT push direct GitHub PRs)
Tracked changes land through the loop: branch → push to jeryu `:8787` → `host-ci` (`jeryu/ci`) →
`agent-review` (`jeryu/agent-review`) → gated `automerge` (FF `update-ref`) → `release-promotion` (signed
local/dev-canary/prod) → `mirror-to-github-main` (SSH). A direct GitHub PR is reverted by the mirror.
