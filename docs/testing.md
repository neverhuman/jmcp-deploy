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

## Acceptance Criteria

A JMCP V1 change is not complete unless it identifies the affected proof lanes and either adds coverage or explains why existing coverage already proves the claim. Documentation claims in the final paper should map to `agent/proof-lanes.toml` and this test strategy, and release candidates must satisfy `docs/release.md`.
