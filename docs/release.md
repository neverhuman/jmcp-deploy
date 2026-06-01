# JMCP Release Gate

Release is the result of a clean local proof set, not a separate ceremony.

## Required Gate

- `just fast`
- `just conformance`
- `just security`
- `cargo test --workspace --all-targets --locked`
- `npm --workspace @jmcp/cockpit run build`
- `npm --prefix apps/web run build`
- `npm --prefix apps/web run test:ux`

## Baseline Rule

The committed score baseline lives in `agent/repo-score-baseline.json`. Update it only after the new advisory report has a strictly better `score` and `raw_score`, does not add caps, and does not increase any rule count.

## Evidence

Release evidence should point at the local artifacts the lanes already emit:

- `target/jankurai/repo-score.json`
- `target/jankurai/repo-score.md`
- `target/jankurai/security/evidence.json`
- `target/jankurai/ux-qa.json`
- `target/jankurai/repair-queue.jsonl`

