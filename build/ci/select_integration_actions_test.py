#!/usr/bin/env python3
"""Tests for build/ci/select_integration_actions.py."""

from __future__ import annotations

import contextlib
import io
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest
from unittest import mock

from build.ci import select_integration_actions
from build.ci.select_integration_actions import ACTIONS, CORE_TARGETS, WEB_NG_TARGETS, decide, source_label


def completed(returncode: int, stdout: str = "", stderr: str = "") -> subprocess.CompletedProcess:
    return subprocess.CompletedProcess(args=["bazel"], returncode=returncode, stdout=stdout, stderr=stderr)


# An invented graph: each action's test targets and what every target depends on.
ACTION_TESTS = {
    CORE_TARGETS: {"//core:integration_test"},
    WEB_NG_TARGETS: {"//web:db_test"},
}
DEPS = {
    "//core:integration_test": {"//core:lib", "//shared:lib"},
    "//web:db_test": {"//web:lib", "//shared:lib"},
    "//core:lib": {"//core:device.ex"},
    "//web:lib": {"//web:live.ex"},
    "//shared:lib": {"//shared:schema.ex"},
    "//go:lib": {"//go:scanner.go"},
}
KNOWN = set(DEPS) | {label for deps in DEPS.values() for label in deps} | set().union(*ACTION_TESTS.values())
AFFECTED_QUERY = re.compile(r"^let t = \((?P<targets>.*)\) in \$t intersect rdeps\(deps\(\$t\), set\((?P<labels>[^()]*)\)\)$")


def closure(roots: set[str]) -> set[str]:
    seen, stack = set(), list(roots)
    while stack:
        node = stack.pop()
        if node not in seen:
            seen.add(node)
            stack.extend(DEPS.get(node, ()))
    return seen


class GraphQuery:
    """Evaluates exactly the two query shapes decide() should send against the graph above.

    Any other expression is an unknown query and fails, so a selector that asks a
    different question (deps instead of rdeps, no action restriction) runs everything.
    """

    def __init__(self, fail: str | None = None):
        self.fail = fail
        self.calls: list[list[str]] = []

    def __call__(self, args):
        self.calls.append(list(args))
        expression = args[-1]
        if expression.startswith("set("):
            if self.fail == "existence":
                return completed(7)
            labels = expression[len("set("):-1].split()
            if self.fail == "loading":
                return completed(3, "", "ERROR: error loading package 'go': BUILD file syntax error\n")
            present = [label for label in labels if label in KNOWN]
            missing = "".join(f"ERROR: no such target '{label}'\n" for label in labels if label not in KNOWN)
            return completed(0 if not missing else 3, "\n".join(present), missing)
        match = AFFECTED_QUERY.match(expression)
        if self.fail == "affected" or not match or match["targets"] not in ACTION_TESTS:
            return completed(7)
        tests = ACTION_TESTS[match["targets"]]
        changed = set(match["labels"].split())
        hits = sorted(test for test in tests if closure({test}) & changed)
        return completed(0, "\n".join(hits))


class SelectIntegrationActionsTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        for package in ("", "core", "web", "shared", "go"):
            (self.root / package / "BUILD.bazel").parent.mkdir(parents=True, exist_ok=True)
            (self.root / package / "BUILD.bazel").write_text("", encoding="utf-8")
        # Every run-all path except the deleted one exists, so only its rule can force the run.
        for source in (
            "MODULE.bazel",
            "buildbuddy.yaml",
            "build/ci/detect_docs_only.py",
            "elixir/web-ng/lane_scope.bzl",
            "elixir/serviceradar_core/priv/repo/migrations/20260101000000_example.exs",
            "rust/integration-db/src/lib.rs",
            "elixir/web-ng/mix.lock",
            "demo/dashboard-kit/package-lock.json",
            "core/device.ex",
            "web/live.ex",
            "shared/schema.ex",
            "go/scanner.go",
            "helm/serviceradar/values.yaml",
        ):
            (self.root / source).parent.mkdir(parents=True, exist_ok=True)
            (self.root / source).write_text("", encoding="utf-8")

    def runs(self, paths, query=None):
        query = query or GraphQuery()
        return {action: decide(action, paths, self.root, query)[0] for action in ACTIONS}

    def test_source_label_uses_the_nearest_package(self):
        self.assertEqual("//go:scanner.go", source_label("go/scanner.go", self.root))
        self.assertEqual("//:helm/serviceradar/values.yaml", source_label("helm/serviceradar/values.yaml", self.root))

    def test_each_action_runs_only_for_its_own_dependencies(self):
        for paths, expected in (
            (["core/device.ex"], {"core": True, "web_ng": False}),
            (["web/live.ex"], {"core": False, "web_ng": True}),
            (["shared/schema.ex"], {"core": True, "web_ng": True}),
            (["go/scanner.go", "helm/serviceradar/values.yaml"], {"core": False, "web_ng": False}),
        ):
            with self.subTest(paths=paths):
                self.assertEqual(expected, self.runs(paths))

    def test_docs_only_change_skips_every_action_without_querying(self):
        query = GraphQuery()
        self.assertEqual({"core": False, "web_ng": False}, self.runs(["docs/agent-runbooks.md"], query))
        self.assertEqual([], query.calls)

    def test_build_definitions_fixture_inputs_and_deletions_run_without_querying(self):
        for path in (
            "MODULE.bazel",
            "buildbuddy.yaml",
            "build/ci/detect_docs_only.py",
            "go/BUILD.bazel",
            "elixir/web-ng/lane_scope.bzl",
            "elixir/serviceradar_core/priv/repo/migrations/20260101000000_example.exs",
            "rust/integration-db/src/lib.rs",
            "elixir/web-ng/mix.lock",
            "demo/dashboard-kit/package-lock.json",
            "go/removed.go",
        ):
            with self.subTest(path=path):
                query = GraphQuery()
                self.assertEqual({"core": True, "web_ng": True}, self.runs([path], query))
                self.assertEqual([], query.calls)

    def test_query_failures_run_the_action(self):
        for failure in ("existence", "loading", "affected"):
            with self.subTest(failure=failure):
                self.assertEqual(
                    {"core": True, "web_ng": True},
                    self.runs(["go/scanner.go"], GraphQuery(fail=failure)),
                )


class MainEventTest(unittest.TestCase):
    """main() skips only on a pull request or when no event is set, as detect_docs_only does."""

    def run_main(self, event_env):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        marker = Path(tmp.name) / "skip-core"
        env = {
            key: value
            for key, value in os.environ.items()
            if key not in ("BUILDBUDDY_EVENT", "CI_EVENT", "GITHUB_EVENT_NAME")
        }
        env.update(event_env, SERVICERADAR_SKIP_MARKER=str(marker), GIT_BASE_BRANCH="staging")
        query = GraphQuery()
        with mock.patch.dict(os.environ, env, clear=True), mock.patch.object(
            select_integration_actions, "resolve_merge_base", return_value="0123456789abcdef"
        ), mock.patch.object(
            select_integration_actions, "get_changed_paths", return_value=["docs/agent-runbooks.md"]
        ), mock.patch.object(select_integration_actions, "bazel_query", query), contextlib.redirect_stdout(
            io.StringIO()
        ):
            self.assertEqual(0, select_integration_actions.main(["--action", "core"]))
        return marker

    def test_no_event_set_diffs_against_the_merge_base_and_skips_a_docs_only_change(self):
        # BuildBuddy workflows set none of the event variables.
        self.assertTrue(self.run_main({}).is_file())

    def test_a_set_non_pull_request_event_runs_in_full(self):
        self.assertFalse(self.run_main({"BUILDBUDDY_EVENT": "push"}).exists())


if __name__ == "__main__":
    unittest.main()
