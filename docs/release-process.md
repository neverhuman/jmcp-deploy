# Release Process Doc

This release process doc is the step-by-step operator surface for JMCP releases. Releases are local-first: hosted CI may confirm the same lanes, but it does not replace local proof.

## Required Local Gates

Run these from the canonical repository root before creating a release receipt:

1. `just fast`
2. `just contract-drift`
3. `just conformance`
4. `just security`
5. `just ux-qa`
6. `just cost-budget`
7. `just release-readiness`
8. `cargo test --workspace --all-targets --locked`
9. `npm --workspace @jmcp/cockpit run build`
10. `npm --prefix apps/web run build`
11. `npm --prefix apps/web run test:ux`
12. `just score`

If a lane fails, stop and keep the emitted receipt under `target/jankurai/` with the failed command in the repair note.

## Receipt Contents

Each release receipt records:

- source commit SHA and tag name;
- version source from `agent/standard-version.toml`, relevant manifests, and `CHANGELOG.md`;
- `target/jankurai/` proof artifacts;
- security evidence from `target/jankurai/security/evidence.json`;
- cost and release receipts from `target/jankurai/cost-budget.json` and `target/jankurai/release-readiness.json`;
- UX receipts and screenshots when a rendered surface changed;
- migration, restore, and rollback evidence when durable state changed;
- previous released artifact checksum or rollback target.

## Tagging

Tag only after the receipt names the exact source commit and all required gates are green. Do not tag from an uncommitted worktree or from hosted-only state.

## Remote Promotion

Use `just publish-main` to promote a reviewed `main` tip to the GitHub remote. The command reruns the PR CI gates, confirms the branch is clean, and refuses any history that still contains merge commits since `github/main`. GitHub branch protection on `main` is intentionally linear, so squash or rebase feature work before promotion.

## Rollback

Rollback restores the prior signed or reviewed artifact, restores the pre-migration SQLite copy when schema changed, reruns the affected smoke checks, and keeps mutating traffic closed until the rollback receipt is attached.
