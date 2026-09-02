#!/usr/bin/env python3
"""Fail-closed checks for the source-only public release tree.

This uses only the Python standard library so it can run before a repository is
initialized and on the stock Python shipped by a macOS or Ubuntu runner.
"""

from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
VERSION_RE = re.compile(
    r"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$"
)
ACTION_RE = re.compile(
    r"^- uses: [A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+@[0-9a-f]{40} # v\d[^ ]*$"
)
PUBLIC_FILES = {
    ".github/workflows/ci.yml",
    ".github/workflows/release.yml",
    ".gitignore",
    "CHANGELOG.md",
    "INSTALL.md",
    "LICENSE",
    "Package.swift",
    "README.md",
    "SECURITY.md",
    "VERSION",
    "build-app.sh",
    "scripts/check-version.sh",
    "scripts/release_contract.py",
    "Tests/test_release_contract.py",
}
DENY_PARTS = {
    ".build",
    ".DS_Store",
    ".firecrawl",
    "LUNA_HANDOFF.md",
    "OPEN_SOURCE_RELEASE_SPEC.md",
    "__pycache__",
    "dist",
    "notes",
    "otp-bar.app",
}
DENY_SUFFIXES = (".app", ".dSYM", ".zip", ".tar.gz", ".pyc")
DENY_NAMES = {"otp-bar-bin", "otp-bar-arm64", "otp-bar-x86_64", "gitleaks"}


def _is_public_source(path: str) -> bool:
    parts = Path(path).parts
    return (
        len(parts) == 3
        and parts[0] in {"Sources", "Tests"}
        and parts[1] in {"otp-bar", "otp-barTests"}
        and parts[2].endswith(".swift")
    )


def _denied(path: str) -> bool:
    candidate = Path(path)
    return any(part in DENY_PARTS for part in candidate.parts) or any(
        part.endswith(DENY_SUFFIXES) or part in DENY_NAMES for part in candidate.parts
    )


def public_tree_files() -> list[str]:
    """Return files that would be publishable, including pre-git local trees."""

    git_dir = ROOT / ".git"
    if git_dir.exists():
        result = subprocess.run(
            ["git", "ls-files", "-co", "--exclude-standard"],
            cwd=ROOT,
            check=True,
            capture_output=True,
            text=True,
        )
        return sorted(line for line in result.stdout.splitlines() if line)

    files: list[str] = []
    for path in ROOT.rglob("*"):
        if not path.is_file():
            continue
        relative = path.relative_to(ROOT).as_posix()
        if relative == ".git" or relative.startswith(".git/") or _denied(relative):
            continue
        files.append(relative)
    return sorted(files)


def read_version() -> str:
    raw = (ROOT / "VERSION").read_text(encoding="utf-8")
    if raw.endswith("\n"):
        raw = raw[:-1]
    version = raw
    if not VERSION_RE.fullmatch(version):
        raise AssertionError(f"VERSION must be exactly X.Y.Z: {version!r}")
    if "\n" in raw or "\r" in raw:
        raise AssertionError("VERSION must contain exactly one line")
    return version


def assert_tree() -> None:
    files = public_tree_files()
    unexpected = [path for path in files if path not in PUBLIC_FILES and not _is_public_source(path)]
    if unexpected:
        raise AssertionError(f"unexpected publishable files (allowlist failed closed): {unexpected}")
    missing = sorted(PUBLIC_FILES - set(files))
    if missing:
        raise AssertionError(f"required public files missing: {missing}")
    denied = [path for path in files if _denied(path)]
    if denied:
        raise AssertionError(f"denied files would ship: {denied}")


def assert_workflows() -> None:
    workflow_text = {
        path: (ROOT / path).read_text(encoding="utf-8")
        for path in (".github/workflows/ci.yml", ".github/workflows/release.yml")
    }
    for path, text in workflow_text.items():
        uses = [line.strip() for line in text.splitlines() if line.strip().startswith("- uses:")]
        if not uses or any(not ACTION_RE.fullmatch(line) for line in uses):
            raise AssertionError(f"all actions in {path} must use a SHA and version note")
        if "gitleaks_8.30.0_linux_x64.tar.gz" not in text:
            raise AssertionError(f"{path} must run the pinned full-history gitleaks archive")
        if "79a3ab579b53f71efd634f3aaf7e04a0fa0cf206b7ed434638d1547a2470a66e" not in text:
            raise AssertionError(f"{path} must verify the gitleaks archive SHA-256")
        if "sha256sum -c -" not in text or text.index("sha256sum -c -") > text.index("tar -xzf"):
            raise AssertionError(f"{path} must verify gitleaks before extraction")
    ci = workflow_text[".github/workflows/ci.yml"]
    release = workflow_text[".github/workflows/release.yml"]
    if "cancel-in-progress: true" not in ci or "cancel-in-progress: true" not in release:
        raise AssertionError("CI and release workflows must cancel superseded runs")
    if "permissions:\n  contents: read" not in ci or "permissions:\n  contents: read" not in release:
        raise AssertionError("validation workflows must default to contents: read")
    if "fetch-depth: 0" not in ci or "fetch-depth: 0" not in release:
        raise AssertionError("both workflows must check out full history")
    if "upload-artifact" in ci or "upload-artifact" in release:
        raise AssertionError("source-only workflows must not upload app artifacts")
    if "gh release create" not in release or "--verify-tag" not in release:
        raise AssertionError("release must use gh with --verify-tag")
    if "--notes-from-tag" not in release:
        raise AssertionError("release must use annotated-tag notes")
    if re.search(r"gh release create[\s\S]*?--repo(?:\s|=)", release):
        raise AssertionError("--notes-from-tag must use the checked-out local repository")
    if re.search(r"gh release create[^\n]*(?:\.app|\.zip|\.dylib|\.bin|\.tar)", release):
        raise AssertionError("release command must not attach binary assets")
    if "permissions:\n      contents: write" not in release:
        raise AssertionError("only the publishing job may request contents: write")


def assert_metadata() -> None:
    version = read_version()
    build = (ROOT / "build-app.sh").read_text(encoding="utf-8")
    if 'VERSION="$(<"$VERSION_FILE")"' not in build:
        raise AssertionError("build must read VERSION")
    metadata = "<string>${VERSION}</string>"
    if f"CFBundleShortVersionString</key>{metadata}" not in build:
        raise AssertionError("build must derive CFBundleShortVersionString from VERSION")
    if f"CFBundleVersion</key>{metadata}" not in build:
        raise AssertionError("build must derive CFBundleVersion from VERSION")
    if "one.editors.otp-bar" not in build:
        raise AssertionError("bundle identifier compatibility drifted")
    checker = (ROOT / "scripts/check-version.sh").read_text(encoding="utf-8")
    if (
        "CFBundleShortVersionString" not in checker
        or "CFBundleVersion" not in checker
        or "VERSION" not in checker
    ):
        raise AssertionError("standalone plist/version check is incomplete")
    if "^(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)$" not in build:
        raise AssertionError("build version validation drifted from X.Y.Z")
    if "^(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)$" not in checker:
        raise AssertionError("plist checker version validation drifted from X.Y.Z")
    changelog = (ROOT / "CHANGELOG.md").read_text(encoding="utf-8")
    if not re.search(rf"^## \[{re.escape(version)}\](?:\s|$)", changelog, re.MULTILINE):
        raise AssertionError(f"CHANGELOG has no entry for VERSION {version}")
    if "Unreleased" not in changelog or "Keep a Changelog" not in changelog:
        raise AssertionError("changelog must follow Keep a Changelog conventions")
    release = (ROOT / ".github/workflows/release.yml").read_text(encoding="utf-8")
    if "TAG_VERSION" not in release or '"$TAG_VERSION" != "$VERSION"' not in release:
        raise AssertionError("release must compare the tag version with VERSION")
    if (
        "awk 'END {print NR}' VERSION" not in release
        or "^(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)$" not in release
    ):
        raise AssertionError("release workflow version validation drifted from X.Y.Z")


def main() -> int:
    try:
        assert_tree()
        assert_workflows()
        assert_metadata()
    except (AssertionError, OSError, subprocess.CalledProcessError) as error:
        print(f"release contract FAILED: {error}", file=sys.stderr)
        return 1
    print("release contract OK: source-only tree, workflows, and VERSION metadata")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
