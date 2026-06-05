#!/usr/bin/env python3
"""JMCP split manifest parser and validator."""

from __future__ import annotations

import argparse
import json
import pathlib
import sys
import tomllib

REQUIRED = {"jmcp-core", "jmcp-web", "jmcp-talk", "jmcp-deploy"}
REQUIRED_TRUE_FLAGS = ("has_jeryu_std", "onboarded")


def load_manifest(path: pathlib.Path) -> dict:
    with path.open("rb") as handle:
        data = tomllib.load(handle)
    repos = data.get("repo", [])
    if not isinstance(repos, list):
        raise ValueError("manifest must contain [[repo]] entries")
    names = {str(repo.get("name", "")) for repo in repos}
    missing = sorted(REQUIRED - names)
    if missing:
        raise ValueError(f"manifest missing required repos: {', '.join(missing)}")
    for repo in repos:
        name = str(repo.get("name", "<unknown>"))
        for key in ("path", "name", "github_slug", "jeryu_slug", "default_branch"):
            if not repo.get(key):
                raise ValueError(f"{name} missing {key}")
        for key in REQUIRED_TRUE_FLAGS:
            if repo.get(key) is not True:
                raise ValueError(f"{name} must set {key}=true")
    return data


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--manifest",
        default="repos.manifest.toml",
        help="Path to repos.manifest.toml",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="Emit normalized manifest JSON",
    )
    args = parser.parse_args()

    try:
        data = load_manifest(pathlib.Path(args.manifest))
    except Exception as exc:
        print(f"manifest error: {exc}", file=sys.stderr)
        return 1

    if args.json:
        print(json.dumps(data, indent=2, sort_keys=True))
    else:
        for repo in data.get("repo", []):
            print(
                "|".join(
                    [
                        str(repo["name"]),
                        str(repo["path"]),
                        str(repo["github_slug"]),
                        str(repo["jeryu_slug"]),
                    ]
                )
            )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
