"""Dependency-free release contract tests."""

import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from scripts.release_contract import (  # noqa: E402
    ACTION_RE,
    assert_metadata,
    assert_tree,
    assert_workflows,
    read_version,
    VERSION_RE,
)


class ReleaseContractTests(unittest.TestCase):
    def test_current_intended_public_tree_passes(self):
        assert_tree()

    def test_workflow_actions_are_exact_sha_pinned_with_version_notes(self):
        assert_workflows()
        for workflow in (ROOT / ".github/workflows").glob("*.yml"):
            uses = [
                line.strip()
                for line in workflow.read_text(encoding="utf-8").splitlines()
                if line.strip().startswith("- uses:")
            ]
            self.assertTrue(all(ACTION_RE.fullmatch(line) for line in uses))

    def test_version_build_and_tag_contract_cannot_drift(self):
        assert_metadata()

    def test_version_accepts_only_apple_x_y_z_numbers(self):
        for version in ("0.0.0", "1.0.0", "10.20.300"):
            self.assertIsNotNone(VERSION_RE.fullmatch(version))
        for version in (
            "1.0.0-alpha",
            "1.0.0-alpha..1",
            "1.0",
            "01.2.3",
            "1.02.3",
            "1.2.03",
            "1.0.0\n2.0.0",
            " 1.0.0",
            "1.0.0 ",
            "",
            "1..0",
            "-1.0.0",
        ):
            self.assertIsNone(VERSION_RE.fullmatch(version), repr(version))
        self.assertEqual(read_version(), "0.1.0")

    def test_numeric_version_bump_with_matching_changelog_is_accepted(self):
        with tempfile.TemporaryDirectory() as temporary:
            copy = Path(temporary) / "otp-bar"
            shutil.copytree(
                ROOT,
                copy,
                ignore=shutil.ignore_patterns(
                    ".build", ".DS_Store", ".git", "dist", "notes", "otp-bar.app", "otp-bar-bin"
                ),
            )
            (copy / "VERSION").write_text("1.2.3\n", encoding="utf-8")
            changelog = (copy / "CHANGELOG.md").read_text(encoding="utf-8")
            (copy / "CHANGELOG.md").write_text(
                changelog.replace("## [0.1.0]", "## [1.2.3]", 1), encoding="utf-8"
            )
            subprocess.run(["git", "init", "-q"], cwd=copy, check=True)
            subprocess.run(
                ["git", "config", "user.name", "Release Contract Test"], cwd=copy, check=True
            )
            subprocess.run(
                ["git", "config", "user.email", "release-contract@example.invalid"],
                cwd=copy,
                check=True,
            )
            subprocess.run(["git", "add", "--all"], cwd=copy, check=True)
            subprocess.run(
                ["git", "commit", "-qm", "temporary release contract tree"], cwd=copy, check=True
            )
            result = subprocess.run(
                [sys.executable, str(copy / "scripts/release_contract.py")],
                cwd=copy,
                env={**os.environ, "PYTHONDONTWRITEBYTECODE": "1"},
                capture_output=True,
                text=True,
            )
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_release_workflow_has_no_binary_asset_upload(self):
        release = (ROOT / ".github/workflows/release.yml").read_text(encoding="utf-8")
        self.assertNotIn("upload-artifact", release)
        self.assertNotRegex(release, r"gh release create[^\n]*(?:\\.app|\\.zip|\\.dylib|\\.bin)")
        self.assertIn("--verify-tag", release)
        self.assertIn("--notes-from-tag", release)
        self.assertNotRegex(release, r"gh release create[\s\S]*?--repo(?:\s|=)")

    def test_tree_guard_script_is_executable_and_passes(self):
        script = ROOT / "scripts/release_contract.py"
        self.assertTrue(script.is_file())
        self.assertTrue(os.access(script, os.X_OK))
        result = subprocess.run(
            [sys.executable, str(script)], cwd=ROOT, capture_output=True, text=True
        )
        self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == "__main__":
    unittest.main()
