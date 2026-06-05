from __future__ import annotations

import importlib.util
import pathlib
import subprocess
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
MANIFEST = ROOT / "repos.manifest.toml"
MANIFEST_PY = ROOT / "ops/split/manifest.py"

spec = importlib.util.spec_from_file_location("manifest", MANIFEST_PY)
manifest = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(manifest)


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

    def test_manifest_contains_onboarded_split_family(self) -> None:
        data = manifest.load_manifest(MANIFEST)
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

        with self.assertRaisesRegex(
            ValueError,
            "jmcp-core must set onboarded=true",
        ):
            manifest.load_manifest(path)

    def test_manifest_rejects_repo_without_jeryu_standard(self) -> None:
        path = self.write_manifest_variant(
            "has_jeryu_std = true",
            "has_jeryu_std = false",
        )

        with self.assertRaisesRegex(
            ValueError,
            "jmcp-core must set has_jeryu_std=true",
        ):
            manifest.load_manifest(path)

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
