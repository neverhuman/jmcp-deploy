# JMCP Deploy Boundaries

Deploy-owned surfaces:
- `ops/split/` launch, health, smoke, and manifest parsing.
- `jeryu-ctl/` local Jeryu orchestration.
- `scripts/` environment verification helpers.
- `repos.manifest.toml` split-family wiring.

Secrets must come from environment variables or authenticated local tooling.
Repository text must not embed token-shaped values.
