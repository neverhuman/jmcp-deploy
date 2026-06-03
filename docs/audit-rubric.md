# Audit Rubric

JMCP audits prioritize evidence over claims. Use this rubric when addressing Jankurai findings, release gates, contract drift, data truth, and generated zones.

## Required Shape

- Source paths are mapped in `agent/owner-map.json`.
- Test paths are mapped in `agent/test-map.json`.
- Generated files are declared in `agent/generated-zones.toml`.
- Boundary types are represented by Rust contracts, SQL migrations or constraints, or generated schema artifacts.
- Runtime claims in docs point to a local proof command or receipt under `target/jankurai/`.

## Top-Level Risk Mapping

- Security, secrets, and agency changes route through `just security`.
- Contracts, data, and generated artifacts route through `just contract-drift` and the relevant fast lane.
- Verification and release changes route through `just release-readiness` and `just score`.
- UI changes route through `just ux-qa` and screenshot receipts.
- Control-plane docs and manifests route through `just score`.

CI evidence must be reproducible locally. A hosted workflow can confirm the same lane, but it does not replace local receipts.

## Known Vibe-Coding Insults

Reject fake-green tests, tautological assertions, silent fallback behavior, unowned files, direct database writes from the wrong layer, mutable generated output, and broad catch-all adapters. Every new path needs a narrow owner, a test-map route, and a local proof command.

## Release Readiness

Release readiness requires a version source, changelog entry, release process doc, local proof set, CI or script evidence, integrity and provenance receipts, and rollback guidance. The canonical release surface is `docs/release.md`; the operator procedure is `docs/release-process.md`.

## Boundary And Data Review

When a change touches `db/`, adapter boundaries, JCP/JPCM schemas, generated contracts, approvals, replay, or audit records, verify that durable truth stays in backend-owned Rust and SQL layers. UI, TUI, Telegram, voice, and adapter code should call the runtime boundary instead of becoming alternate authorities.
