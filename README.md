# jmcp-deploy

Deployment and split-family orchestration for JMCP.

This repository owns launch scripts, environment wiring, health checks, split
manifests, Jeryu/GitHub onboarding receipts, and local service coordination for
`jmcp-core`, `jmcp-web`, and `jmcp-talk`.

## Manifest

`repos.manifest.toml` is the split-family source of truth. It records local
working-copy paths, public GitHub slugs, local Jeryu slugs, profiles, default
branches, and onboarding status.

```bash
ops/split/manifest.sh --manifest repos.manifest.toml
```

## Health And Dry Run

```bash
ops/split/health.sh
ops/split/launch.sh --dry-run
```

`launch.sh --run` starts the configured local core, web, and talk commands. Use
the dry run first so service ports and commands are visible before execution.

## Jeryu Control

`jeryu-ctl/` is copied from the proven split-control pattern and adapted for
JMCP. It should contain scripts and hooks only, not local runtime databases,
locks, WAL files, or secrets.
