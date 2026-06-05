# JMCP Deploy Agent Instructions

This repository follows the runtime toolchain instructions at:

@/home/ubuntu/.codex/RTK.md

## Scope

`jmcp-deploy` owns split-family orchestration, launch scripts, environment
templates, health checks, Jeryu/GitHub onboarding receipts, and local service
wiring for `jmcp-core`, `jmcp-web`, and `jmcp-talk`.

## Agent Rules

- Use the `rtk` prefix for shell commands.
- Treat `AGENT_CHAT.md` as append-only.
- Keep work scoped to `ops/`, `scripts/`, deployment docs, and split-family
  manifest/control-plane wiring.
- Do not embed secrets in launch scripts or receipts.
- Preserve other agents' edits. If a file has changed unexpectedly, inspect and merge rather than overwrite.

## Jankurai

<!-- jankurai generated adapter -->
<!-- jankurai agent request v1 sha256:REPLACE_WITH_HASH -->

Read `agent/JANKURAI_STANDARD.md` before Jankurai-scoped work. For explicit phase or MASTER_PLAN work only, read `agent/MASTER_PLAN.md` before `tips/phases/00-phase-index.md`; otherwise, user-provided implementation or handoff plans are controlling. Keep generated artifacts under their declared source commands.
