# JMCP Release Gate

Release is the result of a clean local proof set, not a separate ceremony.
This is the release control surface for version source, changelog, release
process docs, CI or script evidence, integrity/provenance evidence, and rollback
guidance.

Release process doc: [docs/release-process.md](release-process.md).

`just score` writes the review snapshot to `.jankurai/`; the release bundle and lane receipts live under `target/jankurai/`.

## Version Source

- `agent/standard-version.toml` is the policy source for the standard, schema, and paper edition versions.
- `CHANGELOG.md` is the human release history.
- Workspace crates and apps continue to derive versions from their own manifests; release notes should name the specific crate or app version they are shipping.

## Required Proof Set

Run the local proof set in this order:

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

`just release-readiness` is the final release surface check. It validates that this doc, `docs/testing.md`, `docs/operations.md`, and `agent/cost-budget.toml` still describe the same local proof set and receipts.

The step-by-step operator process lives in `docs/release-process.md`.

## Required Receipts

Keep the release proof bundle local and reviewable:

- `target/jankurai/repo-score.json`
- `target/jankurai/repo-score.md`
- `target/jankurai/security/evidence.json`
- `target/jankurai/ux-qa.json`
- `target/jankurai/ux-qa/`
- `target/jankurai/cost-budget.json`
- `target/jankurai/release-readiness.json`
- `target/jankurai/repair-queue.jsonl`

If a lane produces a supporting receipt elsewhere in `target/jankurai/`, keep it with the bundle and cite it in the release note or repair note.

## Release Flow

1. Run the required proof set locally.
2. Review `target/jankurai/repo-score.json` and `target/jankurai/repo-score.md` together with the lane receipts listed above.
3. Compare the candidate advisory report with `agent/repo-score-baseline.json`.
4. Confirm the candidate has a strictly better `score` and `raw_score`, does not introduce new caps, and does not increase any rule count.
5. Confirm the conformance lane still covers the deterministic adversarial fixtures for prompt injection, tool poisoning, memory poisoning, voice replay, false evidence, and CI forgery.
6. Update `CHANGELOG.md` with the user-facing delta.
7. Tag the release from the reviewed commit only after the proof artifacts are stable.

## Baseline Rule

The committed score baseline lives in `agent/repo-score-baseline.json`. Update it only after the new advisory report is strictly better on both `score` and `raw_score`, does not add caps, and does not increase any rule count.

## Integrity And Provenance

- Keep `target/jankurai/repo-score.json` and `target/jankurai/repo-score.md` with the release evidence.
- Keep `target/jankurai/security/evidence.json` with the security lane output.
- Keep `target/jankurai/ux-qa.json` and the screenshot bundle under `target/jankurai/ux-qa/`.
- Keep `target/jankurai/cost-budget.json` and `target/jankurai/release-readiness.json` with the release receipts.
- Keep `target/jankurai/repair-queue.jsonl` for review and replay of any follow-up work.

## Rollback

Rollback should prefer reverting the release commit and restoring the previous tag rather than mutating release history in place. If a release needs to be withdrawn, document the reason in `CHANGELOG.md`, regenerate the local proof set, and only then cut a replacement release from a clean commit.
