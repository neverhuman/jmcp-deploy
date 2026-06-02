# JMCP Release Gate

Release is the result of a clean local proof set, not a separate ceremony.

## Version Source

- `agent/standard-version.toml` is the release-policy source for the standard, schema, and paper edition versions.
- `CHANGELOG.md` is the human-readable release history.
- Workspace crates and apps continue to derive their versions from their own manifests; release notes should name the specific crate or app version they are shipping.

## Required Gate

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

## Release Process

1. Run the full local proof set.
2. Inspect `target/jankurai/repo-score.json`, `target/jankurai/repo-score.md`, and the lane receipts before cutting a release.
3. Confirm the advisory score is strictly better than the committed baseline and that no new caps were introduced.
4. Update `CHANGELOG.md` with the user-facing delta.
5. Tag the release from the reviewed commit only after the proof artifacts are stable.

## Baseline Rule

The committed score baseline lives in `agent/repo-score-baseline.json`. Update it only after the new advisory report has a strictly better `score` and `raw_score`, does not add caps, and does not increase any rule count.

## Integrity and Provenance

- Keep `target/jankurai/repo-score.json` and `target/jankurai/repo-score.md` with the release evidence.
- Keep `target/jankurai/security/evidence.json` with the security lane output.
- Keep `target/jankurai/ux-qa.json` and the screenshot bundle under `target/jankurai/ux-qa/`.
- Keep `target/jankurai/cost-budget.json` and `target/jankurai/release-readiness.json` with the release receipts.
- Keep `target/jankurai/repair-queue.jsonl` for review and replay of any follow-up work.

## Rollback

Rollback should prefer reverting the release commit and restoring the previous tag rather than mutating release history in place. If a release needs to be withdrawn, document the reason in `CHANGELOG.md`, regenerate the local proof set, and only then cut a replacement release from a clean commit.
