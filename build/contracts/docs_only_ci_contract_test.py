#!/usr/bin/env python3
"""A docs-only change runs no heavy CI in any system, and a code change still runs it.

build/ci/detect_docs_only.py is the one definition of a docs-only change. GitHub Actions
cannot import it, so every push or pull_request workflow carries a `paths:` filter that
mirrors it. This contract evaluates those filters with GitHub's ordered, last-match-wins
semantics against that definition, checks that the required BuildBuddy actions always
start, and runs the no-mistakes gate commands against docs-only and code diffs.
"""

from __future__ import annotations

import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

import yaml

from build.ci import detect_docs_only as detect_docs_only_module
from build.ci.detect_docs_only import (
    BUILD_INPUT_PATTERNS,
    DOCS_PATTERNS,
    github_filter_matches,
    github_paths_filter,
    is_docs_only_path,
)


ROOT = Path(__file__).resolve().parents[2]
WORKFLOWS = ROOT / ".github/workflows"

# Workflows that still run on a docs-only change, and why.
EXEMPT_WORKFLOWS = {
    # Builds and deploys the documentation site; docs changes are its whole input.
    "docs-pages.yml",
}

# Statuses the staging ruleset requires. BuildBuddy has no path filters, so each of these
# actions must start on every pull request and post success after a docs-only skip.
REQUIRED_BUILDBUDDY_ACTIONS = ("BazelCI", "BazelCI Core Integration", "BazelCI Web-NG DB")

DOCS_ONLY_DIFF = (
    "CHANGELOG",
    "README.md",
    "elixir/web-ng/AGENTS.md",
    "rust/netprobe/ebpf/README.md",
    "helm/serviceradar/README.md",
    "elixir/web-ng/assets/patches/README.md",
    "proto/README.md",
    ".agents/skills/example/SKILL.md",
    "docs/docs/architecture.md",
    "docs/package.json",
    "openspec/changes/example-change/tasks.md",
    "openspec/specs/example/spec.md",
)


def _expand(pattern: str) -> list[str]:
    """Concrete paths one pattern matches, Markdown and code, nested and hidden."""
    paths = [pattern.lstrip("!")]
    for token, choices in (
        ("**/", ("", "nested/dir/", ".hidden/")),
        ("**", ("file.ex", "nested/README.md", "nested/dir/main.go", ".hidden/conf.yml")),
        ("*", ("sample",)),
        ("?", ("x",)),
    ):
        expanded = []
        for path in paths:
            if token not in path:
                expanded.append(path)
                continue
            head, tail = path.split(token, 1)
            tail = tail.replace(token, choices[0])
            expanded.extend(head + choice + tail for choice in choices)
        paths = expanded
    return paths


def _tracked_paths() -> list[str]:
    """Every tracked path when a git checkout is present; nothing inside a Bazel sandbox."""
    try:
        result = subprocess.run(
            ["git", "-C", str(ROOT), "ls-files"],
            capture_output=True,
            text=True,
            check=False,
        )
    except OSError:
        return []
    return result.stdout.splitlines() if result.returncode == 0 else []


def _push_or_pull_request_filters(workflow: dict) -> dict[str, list[str] | None]:
    """Map each branch-push or pull_request event to its paths filter (None when absent)."""
    on = workflow.get(True, workflow.get("on")) or {}
    if isinstance(on, (str, list)):
        events = [on] if isinstance(on, str) else on
        on = {event: None for event in events}
    filters: dict[str, list[str] | None] = {}
    for event in ("push", "pull_request", "pull_request_target"):
        if event not in on:
            continue
        config = on[event] or {}
        if event == "push" and "tags" in config and "branches" not in config:
            continue
        if "paths-ignore" in config:
            raise AssertionError(f"{event} uses paths-ignore; use a paths filter with negations")
        filters[event] = config.get("paths")
    return filters


def _scope(filter_patterns: list[str]) -> list[str]:
    """The patterns before the first negation: what the workflow covered before docs were cut."""
    scope = []
    for pattern in filter_patterns:
        if pattern.startswith("!"):
            break
        scope.append(pattern)
    return scope


def _triggers(filter_patterns: list[str], diff) -> bool:
    """GitHub runs the workflow when any changed path survives the filter."""
    return any(github_filter_matches(filter_patterns, path) for path in diff)


class DocsOnlyCiContractTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.workflows = {
            path.name: yaml.safe_load(path.read_text(encoding="utf-8"))
            for path in sorted(WORKFLOWS.glob("*.y*ml"))
        }
        corpus = set(DOCS_ONLY_DIFF)
        for pattern in (*DOCS_PATTERNS, *BUILD_INPUT_PATTERNS, *github_paths_filter()):
            corpus.update(_expand(pattern))
        for workflow in cls.workflows.values():
            for filter_patterns in _push_or_pull_request_filters(workflow).values():
                for pattern in filter_patterns or ():
                    expanded = _expand(pattern)
                    corpus.update(expanded)
                    for path in expanded:
                        corpus.add(f"{path.rsplit('/', 1)[0]}/README.md" if "/" in path else "README.md")
        corpus.update(_tracked_paths())
        cls.corpus = sorted(path for path in corpus if path and not path.endswith("/"))
        cls.docs_paths = [path for path in cls.corpus if is_docs_only_path(path)]
        cls.code_paths = [path for path in cls.corpus if not is_docs_only_path(path)]

    def gated_filters(self):
        for name, workflow in self.workflows.items():
            if name in EXEMPT_WORKFLOWS:
                continue
            for event, filter_patterns in _push_or_pull_request_filters(workflow).items():
                yield name, event, filter_patterns

    def test_workflow_inventory_is_checked(self):
        self.assertIn("golangci-lint.yml", self.workflows)
        self.assertTrue(set(EXEMPT_WORKFLOWS) <= set(self.workflows), "stale exemption")
        self.assertGreater(len(list(self.gated_filters())), 10)

    def test_every_push_and_pull_request_workflow_has_a_paths_filter(self):
        for name, event, filter_patterns in self.gated_filters():
            with self.subTest(workflow=name, event=event):
                self.assertTrue(
                    filter_patterns,
                    "runs on docs-only changes; add the filter from "
                    "`python3 build/ci/detect_docs_only.py --print-github-paths`",
                )

    def test_every_filter_is_derived_from_the_shared_definition(self):
        for name, event, filter_patterns in self.gated_filters():
            if not filter_patterns:
                continue
            scope = _scope(filter_patterns)
            if "**" in scope:
                expected = github_paths_filter()
            elif any(github_filter_matches(scope, path) for path in self.docs_paths):
                expected = github_paths_filter(scope)
            else:
                # Lists only paths that can never be docs, such as named scripts.
                expected = scope
            with self.subTest(workflow=name, event=event):
                self.assertEqual(expected, filter_patterns)

    def test_docs_only_diff_skips_every_gated_workflow(self):
        self.assertTrue(all(is_docs_only_path(path) for path in DOCS_ONLY_DIFF))
        for name, event, filter_patterns in self.gated_filters():
            with self.subTest(workflow=name, event=event):
                self.assertFalse(_triggers(filter_patterns or ["**"], DOCS_ONLY_DIFF))
                leaking = [path for path in self.docs_paths if github_filter_matches(filter_patterns or ["**"], path)]
                self.assertEqual([], leaking[:20])

    def test_code_in_scope_still_runs_every_gated_workflow(self):
        for name, event, filter_patterns in self.gated_filters():
            if not filter_patterns:
                continue
            scope = _scope(filter_patterns)
            with self.subTest(workflow=name, event=event):
                dropped = [
                    path
                    for path in self.code_paths
                    if github_filter_matches(scope, path) and not github_filter_matches(filter_patterns, path)
                ]
                self.assertEqual([], dropped[:20], "the docs-only tail suppressed a code path")
                # Re-included build-input Markdown may reach outside the scope; nothing else may.
                widened = [
                    path
                    for path in self.corpus
                    if github_filter_matches(filter_patterns, path)
                    and not github_filter_matches(scope, path)
                    and not (path.endswith(".md") and not is_docs_only_path(path))
                ]
                self.assertEqual([], widened[:20], "the docs-only tail added paths outside the scope")
                in_scope_code = next(
                    (path for path in self.code_paths if github_filter_matches(scope, path)), None
                )
                self.assertIsNotNone(in_scope_code)
                self.assertTrue(_triggers(filter_patterns, (*DOCS_ONLY_DIFF, in_scope_code)))

    def test_required_buildbuddy_actions_start_on_every_staging_pull_request(self):
        # BuildBuddy has no path filters: a required action that did not start would leave
        # its status pending forever, so each one triggers on every staging pull request and
        # skips its heavy steps from inside.
        config = yaml.safe_load((ROOT / "buildbuddy.yaml").read_text(encoding="utf-8"))
        actions = {action["name"]: action for action in config["actions"]}
        for name in REQUIRED_BUILDBUDDY_ACTIONS:
            with self.subTest(action=name):
                triggers = actions[name]["triggers"]
                self.assertEqual({"pull_request"}, set(triggers))
                self.assertEqual({"branches"}, set(triggers["pull_request"]))
                self.assertIn("staging", triggers["pull_request"]["branches"])


class NoMistakesGateTest(unittest.TestCase):
    """Runs each configured gate command in a scratch repository with a stub `bazel`."""

    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory(prefix="docs-only-gate-")
        self.addCleanup(self.temp_dir.cleanup)
        root = Path(self.temp_dir.name)
        self.repo = root / "repo"
        self.bazel_log = root / "bazel.log"
        bin_dir = root / "bin"
        bin_dir.mkdir()
        for tool in ("bazel", "make"):
            (bin_dir / tool).write_text(f'#!/bin/sh\necho "{tool} $@" >> "{self.bazel_log}"\n', encoding="utf-8")
        (bin_dir / "python3").write_text(f'#!/bin/sh\nexec "{sys.executable}" "$@"\n', encoding="utf-8")
        for stub in bin_dir.iterdir():
            stub.chmod(0o755)
        self.env = {
            key: value
            for key, value in os.environ.items()
            if key not in ("BUILDBUDDY_EVENT", "CI_EVENT", "GITHUB_EVENT_NAME", "GIT_BASE_BRANCH")
        }
        self.env["PATH"] = f"{bin_dir}{os.pathsep}{os.environ.get('PATH', '')}"

        (self.repo / "build/ci").mkdir(parents=True)
        shutil.copy(detect_docs_only_module.__file__, self.repo / "build/ci/detect_docs_only.py")
        (self.repo / "main.go").write_text("package main\n", encoding="utf-8")
        self.git("init", "--quiet", "--initial-branch=staging")
        self.git("add", ".")
        self.commit("base")
        self.git("checkout", "--quiet", "-b", "feature")
        self.gates = yaml.safe_load((ROOT / ".no-mistakes.yaml").read_text(encoding="utf-8"))["gates"]
        self.assertTrue(self.gates)

    def git(self, *args):
        subprocess.run(["git", "-C", str(self.repo), *args], check=True, capture_output=True)

    def commit(self, message):
        self.git("-c", "user.name=CI", "-c", "user.email=ci@example.com", "-c", "commit.gpgsign=false",
                 "commit", "--quiet", "-m", message)

    def run_gates(self):
        """Returns the names of the gates whose command reached `bazel` or `make`."""
        ran = []
        for gate in self.gates:
            self.bazel_log.unlink(missing_ok=True)
            result = subprocess.run(
                ["sh", "-c", gate["command"]], cwd=self.repo, env=self.env, capture_output=True, text=True
            )
            self.assertEqual(0, result.returncode, f"{gate['name']}: {result.stdout}{result.stderr}")
            if self.bazel_log.exists():
                ran.append(gate["name"])
        return ran

    def test_docs_only_diff_skips_every_gate_and_code_diff_runs_them(self):
        every_gate = [gate["name"] for gate in self.gates]

        (self.repo / "CHANGELOG").write_text("v1\n", encoding="utf-8")
        (self.repo / "openspec").mkdir()
        (self.repo / "openspec/proposal.md").write_text("Proposal\n", encoding="utf-8")
        self.git("add", ".")
        self.commit("docs")
        self.assertEqual([], self.run_gates())

        # Go lint runs on the workstation, so a change with no Go in it must not start it.
        (self.repo / "lib.ex").write_text("defmodule Lib do\nend\n", encoding="utf-8")
        self.git("add", ".")
        self.commit("elixir")
        self.assertEqual([name for name in every_gate if name != "go-lint"], self.run_gates())

        (self.repo / "main.go").write_text("package main\n// changed\n", encoding="utf-8")
        self.git("add", ".")
        self.commit("code")
        self.assertEqual(every_gate, self.run_gates())


if __name__ == "__main__":
    unittest.main()
