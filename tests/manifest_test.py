from __future__ import annotations

import json
import pathlib
import subprocess
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
MANIFEST = ROOT / "repos.manifest.toml"
MANIFEST_SH = ROOT / "ops/split/manifest.sh"


class ManifestTest(unittest.TestCase):
    def write_manifest_variant(self, old: str, new: str) -> pathlib.Path:
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        path = pathlib.Path(tmp.name) / "repos.manifest.toml"
        path.write_text(
            MANIFEST.read_text(encoding="utf-8").replace(old, new, 1),
            encoding="utf-8",
        )
        return path

    def run_manifest(self, path: pathlib.Path, *extra: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [str(MANIFEST_SH), "--manifest", str(path), *extra],
            cwd=ROOT,
            check=False,
            text=True,
            capture_output=True,
        )

    def test_manifest_contains_onboarded_split_family(self) -> None:
        result = self.run_manifest(MANIFEST, "--json")
        self.assertEqual(result.returncode, 0, result.stderr)
        data = json.loads(result.stdout)
        repos = {repo["name"]: repo for repo in data["repo"]}
        self.assertEqual(
            set(repos),
            {"jmcp-core", "jmcp-web", "jmcp-talk", "jmcp-deploy"},
        )
        for repo in repos.values():
            self.assertTrue(repo["onboarded"])
            self.assertTrue(repo["has_jeryu_std"])
            self.assertEqual(repo["default_branch"], "main")

    def test_manifest_rejects_not_onboarded_repo(self) -> None:
        path = self.write_manifest_variant("onboarded = true", "onboarded = false")

        result = self.run_manifest(path)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("jmcp-core must set onboarded=true", result.stderr)

    def test_manifest_rejects_repo_without_jeryu_standard(self) -> None:
        path = self.write_manifest_variant(
            "has_jeryu_std = true",
            "has_jeryu_std = false",
        )

        result = self.run_manifest(path)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("jmcp-core must set has_jeryu_std=true", result.stderr)

    def test_offline_health_skips_local_jeryu_dependency(self) -> None:
        result = subprocess.run(
            [str(ROOT / "ops/split/health.sh"), "--offline"],
            cwd=ROOT,
            check=True,
            text=True,
            capture_output=True,
        )
        self.assertIn("mode=offline", result.stdout)

    def test_offline_health_rejects_require_jeryu(self) -> None:
        result = subprocess.run(
            [str(ROOT / "ops/split/health.sh"), "--offline", "--require-jeryu"],
            cwd=ROOT,
            check=False,
            text=True,
            capture_output=True,
        )
        self.assertEqual(result.returncode, 2)
        self.assertIn("[--offline|--require-jeryu]", result.stderr)


if __name__ == "__main__":
    unittest.main()
