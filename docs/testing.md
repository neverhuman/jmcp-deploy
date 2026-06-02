# JMCP V1 Testing Strategy

## Testing Goal

JMCP V1 tests must prove that the local default is production-shaped, deterministic, and replayable. The minimum acceptable bar is CI-local parity: the same default architecture used by developers is exercised by CI without requiring remote services.

## Proof Lanes

The audit-facing lane map is kept in `agent/proof-lanes.toml`. The test map in `agent/test-map.json` routes each owned surface to the command that proves it.

## Required Lanes

- **Unit:** Validate protocol envelopes, policy decisions, event serialization, approval transitions, and adapter error classes.
- **Integration-local:** Start the Rust backend against embedded SQLite and the in-process event bus, then prove migrations, publish/replay, approval persistence, and UI-facing contracts.
- **Protocol:** Prove JCP/1.0.0 acceptance and rejection behavior under JPCM, including correlation ids and idempotency keys.
- **Security:** Prove secret redaction, approval enforcement, adapter boundary checks, and replay side-effect safety.
- **Operations:** Prove cold start, restart, database reuse, audit export, and degraded-mode behavior.
- **Reproducibility:** Prove committed fixtures and generated zones are sufficient to reproduce claims locally.
- **Rendered UX:** Prove the live cockpit UI and the `apps/web` proof host with Playwright screenshots and accessibility checks.

## Fixture Rules

Fixtures should be small, explicit, and deterministic. Time, ids, and external responses should be controlled by test harnesses. Telegram and local adapters should default to fake/local drivers in tests unless a separate opt-in external lane is declared.

## Cost Budgets

Any test or proof that can consume paid API credits, external quotas, or metered cloud resources must declare an explicit budget before it runs. The default budget is zero external spend. The machine-readable policy lives in `agent/cost-budget.toml` and is verified by `just cost-budget`, which writes `target/jankurai/cost-budget.json`.

If a lane needs an exception, document the cap in the lane recipe, keep the proof replayable with a local substitute, and update the receipt before running the lane. Unknown paid tools, missing receipts, exceeded quotas, and the `JMCP_COST_KILL_SWITCH=1` kill switch are stop conditions.

## Stop Conditions

Abort a lane as soon as one of these happens:

- a command begins hitting an external service that was not declared in the lane recipe;
- a replay or retry can duplicate durable side effects;
- a proof requires manual intervention that cannot be captured as a receipt;
- a budget or quota is about to be exceeded and there is no local fallback.

## Repair Receipts

When a proof fails, write down the exact rerun command and the artifact path that explains the failure. Preferred receipts are the existing local artifacts:

- `target/jankurai/repo-score.json`
- `target/jankurai/repo-score.md`
- `target/jankurai/security/evidence.json`
- `target/jankurai/ux-qa.json`
- `target/jankurai/cost-budget.json`
- `target/jankurai/release-readiness.json`
- `target/jankurai/repair-queue.jsonl`

If a lane is retried, the rerun command should be copy-pastable and should not depend on hidden agent state.

## Replayable Reruns

The standard rerun commands are:

- `just fast`
- `just contract-drift`
- `just conformance`
- `just security`
- `just ux-qa`
- `just cost-budget`
- `just release-readiness`
- `cargo test --workspace --all-targets --locked`
- `npm --workspace @jmcp/cockpit run build`
- `npm --prefix apps/web run build`
- `npm --prefix apps/web run test:ux`

## Launch Gate Evidence

Release readiness needs more than command names. The release gate should be able to point at:

- security evidence in `docs/security.md` and `target/jankurai/security/evidence.json`;
- backup and restore expectations in `docs/operations.md`;
- monitoring and replay receipts in `target/jankurai/repo-score.md`, `target/jankurai/ux-qa.json`, and `target/jankurai/repair-queue.jsonl`;
- cost-budget and stop-condition receipts in `agent/cost-budget.toml` and `target/jankurai/cost-budget.json`;
- release readiness in `target/jankurai/release-readiness.json`;
- rollback guidance in `docs/release.md` and `CHANGELOG.md`;
- abuse controls from the approval gate, replay safety, and adapter boundary rules.

## Acceptance Criteria

A JMCP V1 change is not complete unless it identifies the affected proof lanes and either adds coverage or explains why existing coverage already proves the claim. Documentation claims in the final paper should map to `agent/proof-lanes.toml` and this test strategy, and release candidates must satisfy `docs/release.md`.
