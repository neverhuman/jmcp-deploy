from __future__ import annotations

import os
import pathlib
import subprocess
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]


class LaunchTest(unittest.TestCase):
    def test_launch_dry_run_names_split_services(self) -> None:
        result = subprocess.run(
            [str(ROOT / "ops/split/launch.sh"), "--dry-run"],
            cwd=ROOT,
            check=True,
            text=True,
            capture_output=True,
        )
        self.assertIn("core cwd=", result.stdout)
        self.assertIn("web cwd=", result.stdout)
        self.assertIn("talk cwd=", result.stdout)

    def test_launch_dry_run_respects_split_root(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            env = os.environ.copy()
            env["JMCP_SPLIT_ROOT"] = tmp
            result = subprocess.run(
                [str(ROOT / "ops/split/launch.sh"), "--dry-run"],
                cwd=ROOT,
                env=env,
                check=True,
                text=True,
                capture_output=True,
            )

        self.assertIn(f"core cwd={tmp}/jmcp-core", result.stdout)
        self.assertIn(f"web cwd={tmp}/jmcp-web", result.stdout)
        self.assertIn(f"talk cwd={tmp}/jmcp-talk", result.stdout)

    def test_launch_rejects_unknown_mode(self) -> None:
        result = subprocess.run(
            [str(ROOT / "ops/split/launch.sh"), "--bad-mode"],
            cwd=ROOT,
            check=False,
            text=True,
            capture_output=True,
        )

        self.assertEqual(result.returncode, 2)
        self.assertIn("[--dry-run|--run]", result.stderr)


if __name__ == "__main__":
    unittest.main()
