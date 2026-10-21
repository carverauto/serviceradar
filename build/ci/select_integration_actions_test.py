#!/usr/bin/env python3
"""Tests for build/ci/select_integration_actions.py."""

from __future__ import annotations

from pathlib import Path
import subprocess
import tempfile
import unittest

from build.ci.select_integration_actions import ACTIONS, decide, source_label


def completed(returncode: int, stdout: str = "") -> subprocess.CompletedProcess:
    return subprocess.CompletedProcess(args=["bazel"], returncode=returncode, stdout=stdout, stderr="")


class FakeQuery:
    """Answers the two queries decide() makes: label existence, then affected targets."""

    def __init__(self, known: set[str], affected: dict[str, list[str]], fail: str | None = None):
        self.known = known
        self.affected = affected
        self.fail = fail
        self.calls: list[list[str]] = []

    def __call__(self, args):
        self.calls.append(list(args))
        expression = args[-1]
        if expression.startswith("set("):
            if self.fail == "existence":
                return completed(7)
            labels = expression[len("set("):-1].split()
            present = [label for label in labels if label in self.known]
            return completed(0 if len(present) == len(labels) else 3, "\n".join(present))
        if self.fail == "affected":
            return completed(7)
        hits = sorted({target for label, targets in self.affected.items() if label in expression for target in targets})
        return completed(0, "\n".join(hits))


class SelectIntegrationActionsTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        for build in ("BUILD.bazel", "go/pkg/scan/BUILD.bazel", "elixir/serviceradar_core/BUILD.bazel"):
            (self.root / build).parent.mkdir(parents=True, exist_ok=True)
            (self.root / build).write_text("", encoding="utf-8")
        # Every run-all path except the deleted one exists, so only its rule can force the run.
        for source in (
            "MODULE.bazel",
            "buildbuddy.yaml",
            "build/ci/detect_docs_only.py",
            "elixir/web-ng/lane_scope.bzl",
            "elixir/serviceradar_core/priv/repo/migrations/20260101000000_example.exs",
            "rust/integration-db/src/lib.rs",
            "elixir/web-ng/mix.lock",
            "go/pkg/scan/tcp_scanner.go",
            "elixir/serviceradar_core/lib/serviceradar/inventory/device.ex",
            "helm/serviceradar/values.yaml",
        ):
            (self.root / source).parent.mkdir(parents=True, exist_ok=True)
            (self.root / source).write_text("", encoding="utf-8")
        self.query = FakeQuery(
            known={
                "//go/pkg/scan:tcp_scanner.go",
                "//elixir/serviceradar_core:lib/serviceradar/inventory/device.ex",
            },
            affected={
                "//elixir/serviceradar_core:lib/serviceradar/inventory/device.ex": [
                    "//elixir/serviceradar_core:integration_tests_async"
                ]
            },
        )

    def decide(self, paths, action="core", query=None):
        return decide(action, paths, self.root, query or self.query)

    def test_source_label_uses_the_nearest_package(self):
        self.assertEqual("//go/pkg/scan:tcp_scanner.go", source_label("go/pkg/scan/tcp_scanner.go", self.root))
        self.assertEqual("//:helm/serviceradar/values.yaml", source_label("helm/serviceradar/values.yaml", self.root))

    def test_docs_only_change_skips_every_action_without_querying(self):
        for action in ACTIONS:
            with self.subTest(action=action):
                run, reasons = self.decide(["docs/agent-runbooks.md"], action)
                self.assertFalse(run, reasons)
        self.assertEqual([], self.query.calls)

    def test_change_no_action_target_depends_on_skips(self):
        run, reasons = self.decide(["go/pkg/scan/tcp_scanner.go", "helm/serviceradar/values.yaml"])
        self.assertFalse(run, reasons)

    def test_change_an_action_target_depends_on_runs(self):
        run, reasons = self.decide(["elixir/serviceradar_core/lib/serviceradar/inventory/device.ex"])
        self.assertTrue(run)
        self.assertIn("affected: //elixir/serviceradar_core:integration_tests_async", reasons)

    def test_build_definitions_fixture_inputs_and_deletions_run_without_querying(self):
        for path in (
            "MODULE.bazel",
            "buildbuddy.yaml",
            "build/ci/detect_docs_only.py",
            "go/pkg/scan/BUILD.bazel",
            "elixir/web-ng/lane_scope.bzl",
            "elixir/serviceradar_core/priv/repo/migrations/20260101000000_example.exs",
            "rust/integration-db/src/lib.rs",
            "elixir/web-ng/mix.lock",
            "go/pkg/scan/removed.go",
        ):
            with self.subTest(path=path):
                run, _reasons = self.decide([path])
                self.assertTrue(run)
        self.assertEqual([], self.query.calls)

    def test_query_failures_run_the_action(self):
        for failure in ("existence", "affected"):
            with self.subTest(failure=failure):
                query = FakeQuery(self.query.known, self.query.affected, fail=failure)
                run, _reasons = self.decide(["go/pkg/scan/tcp_scanner.go"], query=query)
                self.assertTrue(run)


if __name__ == "__main__":
    unittest.main()
