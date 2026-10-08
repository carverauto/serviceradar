#!/usr/bin/env python3
"""Tests for build/ci/detect_docs_only.py and scripts/ci/unless_docs_only.sh."""

from __future__ import annotations

import os
from pathlib import Path
import subprocess
import tempfile
import unittest

from build.ci.detect_docs_only import (
    classify_paths,
    detect_docs_only,
    get_changed_paths,
    is_allowlisted,
    is_docs_only_path,
    is_excluded,
    resolve_merge_base,
)


class DetectDocsOnlyPathTest(unittest.TestCase):
    def test_allowlist_matches(self):
        allowlisted = [
            "docs/README.md",
            "docs/docs/dire-identity-model.md",
            "docs/architecture.md",
            "docs/package.json",
            "docs/package-lock.json",
            "docs/sub/dir/nested.txt",
            "openspec/AGENTS.md",
            "openspec/changes/foo/design.md",
            "openspec/specs/bar.md",
            "README.md",
            "AGENTS.md",
            "CLAUDE.md",
            "CONTRIBUTING.md",
            "RELEASE.md",
        ]
        for path in allowlisted:
            with self.subTest(path=path):
                self.assertTrue(is_allowlisted(path), f"{path} should be allowlisted")

    def test_allowlist_non_matches(self):
        not_allowlisted = [
            "go/cmd/wasm-plugins/opentext-nom/docs/configuration.md",
            "go/cmd/wasm-plugins/axis/EXTRACTION_MANIFEST.md",
            "demo/README.md",
            "k8s/starrocks/README.md",
            "helm/serviceradar/README.md",
            "helm/serviceradar/TENANT_RUNTIME.md",
            "helm/serviceradar/tests/README.md",
            "third_party/netprobe_corpora/README.md",
            ".agents/skills/daisyui/SKILL.md",
            "buildbuddy.yaml",
            ".github/workflows/release.yml",
            "go.mod",
            "go.sum",
            "Cargo.toml",
            "Cargo.lock",
            "src/main.rs",
            "lib/foo.ex",
            "scripts/build.sh",
            "",
            "   ",
        ]
        for path in not_allowlisted:
            with self.subTest(path=path):
                self.assertFalse(is_allowlisted(path), f"{path} should not be allowlisted")

    def test_exclusions_match(self):
        excluded = [
            "docs/BUILD.bazel",
            "docs/BUILD",
            "docs/sub/BUILD.bazel",
            "docs/sub/BUILD",
            "openspec/BUILD.bazel",
            "openspec/changes/foo/BUILD",
            "docs/macros.bzl",
            "docs/sub/rules.bzl",
            "openspec/rules.bzl",
            "docs/lint_placeholder.sh",
            "docs/cosign.pub",
            "docs/sigstore/root.json",
            "docs/sigstore/targets/release.pub",
            "openspec/changes/parallelize-core-integration-tests/benchmark.md",
        ]
        for path in excluded:
            with self.subTest(path=path):
                self.assertTrue(is_excluded(path), f"{path} should be excluded")
                self.assertFalse(
                    is_docs_only_path(path),
                    f"{path} should not be classified as docs-only",
                )

    def test_exclusions_non_match(self):
        not_excluded = [
            "docs/README.md",
            "docs/docs/dire-identity-model.md",
            "docs/package.json",
            "docs/package-lock.json",
            "openspec/specs/dire-formal-model.md",
            "openspec/changes/foo/design.md",
            "README.md",
            "CLAUDE.md",
        ]
        for path in not_excluded:
            with self.subTest(path=path):
                self.assertFalse(is_excluded(path), f"{path} should not be excluded")
                self.assertTrue(
                    is_docs_only_path(path),
                    f"{path} should be classified as docs-only",
                )

    def test_classify_paths(self):
        paths = [
            "docs/readme.md",
            "openspec/changes/test.md",
            "README.md",
            "go/pkg/main.go",
            "docs/BUILD.bazel",
            "demo/README.md",
        ]
        docs, code = classify_paths(paths)
        self.assertEqual(
            docs,
            ["docs/readme.md", "openspec/changes/test.md", "README.md"],
        )
        self.assertEqual(
            code,
            ["go/pkg/main.go", "docs/BUILD.bazel", "demo/README.md"],
        )


class DetectDocsOnlyGitIntegrationTest(unittest.TestCase):
    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory(prefix="docs-only-test-")
        self.addCleanup(self.temp_dir.cleanup)
        self.root = Path(self.temp_dir.name)
        self.repo = self.root / "repo"
        self.repo.mkdir()
        self.marker = self.root / "marker"

        self.git("init", "--quiet")
        self.git("config", "user.name", "CI Test")
        self.git("config", "user.email", "ci@example.com")
        self.git("config", "commit.gpgsign", "false")

        # Initial commit on main branch
        (self.repo / "README.md").write_text("# Initial\n", encoding="utf-8")
        (self.repo / "code.go").write_text("package main\n", encoding="utf-8")
        self.git("add", ".")
        self.git("commit", "--quiet", "-m", "Initial commit")
        self.git("branch", "-M", "staging")

    def git(self, *args, check=True):
        return subprocess.run(
            ["git", "-C", str(self.repo), *args],
            capture_output=True,
            text=True,
            check=check,
        )

    def test_pure_docs_change_writes_marker(self):
        self.git("checkout", "-b", "feat/docs-pr")
        docs_dir = self.repo / "docs"
        docs_dir.mkdir()
        (docs_dir / "guide.md").write_text("Guide\n", encoding="utf-8")
        self.git("add", ".")
        self.git("commit", "--quiet", "-m", "Add docs")

        result = detect_docs_only(
            base_branch="staging",
            marker_path=self.marker,
            cwd=self.repo,
        )
        self.assertTrue(result)
        self.assertTrue(self.marker.exists())
        content = self.marker.read_text(encoding="utf-8")
        self.assertIn("docs-only change at HEAD", content)

    def test_mixed_change_does_not_write_marker(self):
        self.git("checkout", "-b", "feat/mixed-pr")
        docs_dir = self.repo / "docs"
        docs_dir.mkdir()
        (docs_dir / "guide.md").write_text("Guide\n", encoding="utf-8")
        (self.repo / "code.go").write_text("package main\n// updated\n", encoding="utf-8")
        self.git("add", ".")
        self.git("commit", "--quiet", "-m", "Mixed change")

        result = detect_docs_only(
            base_branch="staging",
            marker_path=self.marker,
            cwd=self.repo,
        )
        self.assertFalse(result)
        self.assertFalse(self.marker.exists())

    def test_touching_exclusion_does_not_write_marker(self):
        self.git("checkout", "-b", "feat/exclusion-pr")
        docs_dir = self.repo / "docs"
        docs_dir.mkdir()
        (docs_dir / "BUILD.bazel").write_text("# new package\n", encoding="utf-8")
        self.git("add", ".")
        self.git("commit", "--quiet", "-m", "Add docs BUILD")

        result = detect_docs_only(
            base_branch="staging",
            marker_path=self.marker,
            cwd=self.repo,
        )
        self.assertFalse(result)
        self.assertFalse(self.marker.exists())

    def test_rename_from_code_into_docs_does_not_write_marker(self):
        self.git("checkout", "-b", "feat/rename-pr")
        docs_dir = self.repo / "docs"
        docs_dir.mkdir()
        # Move code.go into docs/
        self.git("mv", "code.go", "docs/code.go")
        self.git("commit", "--quiet", "-m", "Move code into docs")

        result = detect_docs_only(
            base_branch="staging",
            marker_path=self.marker,
            cwd=self.repo,
        )
        # Because --no-renames is used, code.go deletion is detected as a code change
        self.assertFalse(result)
        self.assertFalse(self.marker.exists())

    def test_unset_base_branch_fails_to_running_everything(self):
        self.git("checkout", "-b", "feat/docs-pr-2")
        (self.repo / "docs").mkdir(exist_ok=True)
        (self.repo / "docs" / "doc.md").write_text("doc\n", encoding="utf-8")
        self.git("add", ".")
        self.git("commit", "--quiet", "-m", "doc")

        result = detect_docs_only(
            base_branch=None,
            marker_path=self.marker,
            cwd=self.repo,
        )
        self.assertFalse(result)
        self.assertFalse(self.marker.exists())

    def test_unresolvable_base_branch_fails_to_running_everything(self):
        result = detect_docs_only(
            base_branch="nonexistent-branch-xyz",
            marker_path=self.marker,
            cwd=self.repo,
        )
        self.assertFalse(result)
        self.assertFalse(self.marker.exists())

    def test_empty_diff_fails_to_running_everything(self):
        result = detect_docs_only(
            base_branch="staging",
            marker_path=self.marker,
            cwd=self.repo,
        )
        self.assertFalse(result)
        self.assertFalse(self.marker.exists())

    def test_non_pull_request_event_fails_to_running_everything(self):
        self.git("checkout", "-b", "feat/docs-pr-3")
        (self.repo / "docs").mkdir(exist_ok=True)
        (self.repo / "docs" / "doc.md").write_text("doc\n", encoding="utf-8")
        self.git("add", ".")
        self.git("commit", "--quiet", "-m", "doc")

        result = detect_docs_only(
            base_branch="staging",
            marker_path=self.marker,
            event_name="push",
            cwd=self.repo,
        )
        self.assertFalse(result)
        self.assertFalse(self.marker.exists())

    def test_stale_marker_is_removed_even_on_failure(self):
        # Create a stale marker before running
        self.marker.write_text("stale marker\n", encoding="utf-8")
        self.assertTrue(self.marker.exists())

        # Run with unset base branch
        result = detect_docs_only(
            base_branch=None,
            marker_path=self.marker,
            cwd=self.repo,
        )
        self.assertFalse(result)
        self.assertFalse(self.marker.exists())


class UnlessDocsOnlyScriptTest(unittest.TestCase):
    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory(prefix="unless-test-")
        self.addCleanup(self.temp_dir.cleanup)
        self.marker = Path(self.temp_dir.name) / "marker"
        # Find script location
        root = Path(__file__).resolve().parents[2]
        self.script = root / "scripts/ci/unless_docs_only.sh"
        self.assertTrue(self.script.exists(), f"{self.script} must exist")

    def test_skips_when_marker_exists(self):
        self.marker.write_text("marker\n", encoding="utf-8")
        env = dict(os.environ, DOCS_ONLY_MARKER=str(self.marker))
        res = subprocess.run(
            [str(self.script), "false"],  # 'false' would exit 1 if run
            capture_output=True,
            text=True,
            env=env,
        )
        self.assertEqual(res.returncode, 0)
        self.assertIn("docs-only change: BazelCI step skipped", res.stdout)

    def test_runs_command_when_marker_absent(self):
        if self.marker.exists():
            self.marker.unlink()
        env = dict(os.environ, DOCS_ONLY_MARKER=str(self.marker))
        res = subprocess.run(
            [str(self.script), "echo", "hello-world"],
            capture_output=True,
            text=True,
            env=env,
        )
        self.assertEqual(res.returncode, 0)
        self.assertIn("hello-world", res.stdout)

        # Non-zero exit code propagated
        res_fail = subprocess.run(
            [str(self.script), "sh", "-c", "exit 42"],
            capture_output=True,
            text=True,
            env=env,
        )
        self.assertEqual(res_fail.returncode, 42)


if __name__ == "__main__":
    unittest.main()
