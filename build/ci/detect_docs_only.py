#!/usr/bin/env python3
"""The one definition of a docs-only change, for every CI system in this repository.

A change is docs-only when every changed path matches DOCS_PATTERNS and none matches
BUILD_INPUT_PATTERNS. Such a change runs no heavy CI:

  * BuildBuddy (buildbuddy.yaml) has no path filters, so the BazelCI actions still start
    and still post their required statuses. This script writes a marker, and every heavy
    step exits through scripts/ci/unless_docs_only.sh (the database actions through
    build/ci/select_integration_actions.py, which classifies paths with this module).
  * GitHub Actions workflows carry a `paths:` filter derived from these patterns (print it
    with --print-github-paths). build/contracts/docs_only_ci_contract_test.py checks every
    workflow against this module, so the two cannot drift.
  * The no-mistakes gates in .no-mistakes.yaml short-circuit through --check.

LargeIngestionGate is deliberately not short-circuited. It runs on every staging push, on
its own executor pool, and release qualification (build/ci/large_ingestion_gate.py) reads
its status on the tagged commit as proof that the suite ran on that tree.

Patterns use GitHub Actions path-filter syntax: `*` matches within one path segment, `**`
matches across segments, and a leading `**/` also matches zero directories.
"""

from __future__ import annotations

import argparse
import functools
import os
from pathlib import Path
import re
import subprocess
import sys
from typing import Iterable


DEFAULT_MARKER_PATH = "/tmp/serviceradar-docs-only-marker"

# What a docs-only change may touch.
DOCS_PATTERNS = (
    "CHANGELOG",
    "**/*.md",
    "docs/**",
    "openspec/**",
)

# Paths inside DOCS_PATTERNS that a build or test reads. Touching one runs everything.
# Audited against the Markdown sources in the build graph:
#   bazel query 'filter("^//.*\.md$", kind("source file", deps(//...)))'
# and against code that reads Markdown (@external_resource, File.read!, include_str!,
# go:embed). Markdown that only sits in a glob(["**"]) and is never read stays docs.
BUILD_INPUT_PATTERNS = (
    # Bazel package and Starlark files change the build graph wherever they live.
    "**/BUILD",
    "**/BUILD.bazel",
    "**/*.bzl",
    # docs/BUILD.bazel exports these to release and contract targets.
    "docs/lint_placeholder.sh",
    "docs/cosign.pub",
    "docs/sigstore/**",
    # Hashed by //build/contracts:ci_heavy_gate_contract_test.
    "openspec/changes/parallelize-core-integration-tests/benchmark.md",
    # Vendored sources: crates embed their own README.md through include_str!, and vendored
    # Go modules and Swift packages (Arrow.docc) are build inputs of their packages.
    "third_party/**",
    "**/vendor/**",
    "swift/FieldSurvey/LocalPackages/**",
    # Application data and fixtures: web-ng compiles priv/mcp/*.md into the MCP server
    # (@external_resource in lib/serviceradar_web_ng/mcp/docs.ex), and tests read testdata/.
    "**/priv/**",
    "**/testdata/**",
    # Scaffolding the CLI ships and its tests render.
    "js/cli/templates/**",
    # Parsed by go/cmd/wasm-plugins/axis/internal/axisref/compatibility_test.go.
    "go/cmd/wasm-plugins/axis/EXTRACTION_MANIFEST.md",
    # Packaged into the signed plugin bundle (build/wasm_plugins/plugin_inventory.bzl).
    "go/cmd/wasm-plugins/opentext-nom/docs/configuration.md",
    # Named Bazel inputs: exports_files in demo/BUILD.bazel, and the data of
    # //k8s/starrocks:values_cluster_contract_test.
    "demo/README.md",
    "k8s/starrocks/README.md",
)

# GitHub Actions `paths:` filters. GitHub matches the patterns in order and the last match
# decides. The dot-path patterns keep hidden files and directories (.github/, .golangci.yml)
# in a catch-all scope whether or not `**` matches a leading dot.
GITHUB_CATCH_ALL_PATTERNS = ("**", ".*", ".*/**", "**/.*", "**/.*/**")


@functools.lru_cache(maxsize=None)
def _pattern_regex(pattern: str) -> re.Pattern[str]:
    out = []
    index = 0
    while index < len(pattern):
        if pattern.startswith("**/", index):
            out.append("(?:.*/)?")
            index += 3
        elif pattern.startswith("**", index):
            out.append(".*")
            index += 2
        elif pattern[index] == "*":
            out.append("[^/]*")
            index += 1
        elif pattern[index] == "?":
            out.append("[^/]")
            index += 1
        else:
            out.append(re.escape(pattern[index]))
            index += 1
    return re.compile("".join(out) + r"\Z")


def path_matches(pattern: str, path: str) -> bool:
    """Match one GitHub Actions path-filter pattern against a repository-relative path."""
    return _pattern_regex(pattern).match(path) is not None


def github_filter_matches(patterns: Iterable[str], path: str) -> bool:
    """Evaluate an ordered GitHub Actions `paths:` filter for one path: the last match wins."""
    included = False
    for pattern in patterns:
        if pattern.startswith("!"):
            if path_matches(pattern[1:], path):
                included = False
        elif path_matches(pattern, path):
            included = True
    return included


def github_paths_filter(scope: Iterable[str] | None = None) -> list[str]:
    """The `paths:` filter for a workflow that must not run on a docs-only change.

    With no scope the workflow covers every path: the docs patterns are negated after the
    catch-all and the build inputs re-included after them. With a scope (a workflow that
    already lists its paths) only Markdown can be docs inside it, so Markdown is negated
    and the Markdown build inputs re-included. Those re-includes are not limited to the
    scope, so the workflow may also run for a build-input Markdown file outside it, never
    for a docs-only path.
    """
    if scope is None:
        return [
            *GITHUB_CATCH_ALL_PATTERNS,
            *(f"!{pattern}" for pattern in DOCS_PATTERNS),
            *BUILD_INPUT_PATTERNS,
        ]
    markdown_inputs = [
        pattern if pattern.endswith(".md") else f"{pattern}/*.md"
        for pattern in BUILD_INPUT_PATTERNS
        if pattern.endswith(".md") or pattern.endswith("/**")
    ]
    return [*scope, "!**/*.md", *markdown_inputs]


def _normalize(path: str) -> str:
    return path.strip().lstrip("/")


def is_allowlisted(path: str) -> bool:
    """Return True if path matches DOCS_PATTERNS."""
    path = _normalize(path)
    return bool(path) and any(path_matches(pattern, path) for pattern in DOCS_PATTERNS)


def is_excluded(path: str) -> bool:
    """Return True if path matches BUILD_INPUT_PATTERNS, requiring a full build/test run."""
    path = _normalize(path)
    return bool(path) and any(path_matches(pattern, path) for pattern in BUILD_INPUT_PATTERNS)


def is_docs_only_path(path: str) -> bool:
    """Return True if a changed path is considered documentation-only."""
    return is_allowlisted(path) and not is_excluded(path)


def classify_paths(paths: Iterable[str]) -> tuple[list[str], list[str]]:
    """Partition paths into docs-only paths and code/exclusion paths."""
    docs_only: list[str] = []
    code: list[str] = []
    for path in paths:
        path = path.strip()
        if not path:
            continue
        if is_docs_only_path(path):
            docs_only.append(path)
        else:
            code.append(path)
    return docs_only, code


def resolve_merge_base(
    base_branch: str,
    runner=subprocess.run,
    cwd: str | Path | None = None,
) -> str | None:
    """Resolve git merge-base between HEAD and base_branch."""
    candidates = [
        f"origin/{base_branch}",
        f"refs/remotes/origin/{base_branch}",
        base_branch,
    ]
    for candidate in candidates:
        try:
            res = runner(
                ["git", "merge-base", "HEAD", candidate],
                capture_output=True,
                text=True,
                check=False,
                cwd=cwd,
            )
            if res.returncode == 0:
                sha = res.stdout.strip()
                if len(sha) == 40 and all(c in "0123456789abcdefABCDEF" for c in sha):
                    return sha
        except OSError:
            return None
    return None


def get_changed_paths(
    base_commit: str,
    runner=subprocess.run,
    cwd: str | Path | None = None,
) -> list[str] | None:
    """Get list of changed file paths between base_commit and HEAD with --no-renames."""
    try:
        res = runner(
            ["git", "diff", "--name-only", "--no-renames", base_commit, "HEAD"],
            capture_output=True,
            text=True,
            check=False,
            cwd=cwd,
        )
        if res.returncode != 0:
            return None
        return [p for p in res.stdout.splitlines() if p.strip()]
    except OSError:
        return None


def docs_only_change(
    base_branch: str | None = None,
    event_name: str | None = None,
    runner=subprocess.run,
    cwd: str | Path | None = None,
) -> tuple[str, int] | None:
    """Return (merge base, file count) when HEAD is a docs-only change, else None.

    Every doubt resolves to None, which runs everything: a non-pull-request event, an
    unset or unresolvable base branch, a failed or empty diff.
    """
    if event_name is None:
        event_name = (
            os.environ.get("BUILDBUDDY_EVENT")
            or os.environ.get("CI_EVENT")
            or os.environ.get("GITHUB_EVENT_NAME")
        )
    if event_name and event_name.lower() not in ("pull_request", "pr"):
        print(f"[detect_docs_only] Event '{event_name}' is not a pull_request; full CI will run.")
        return None

    if not base_branch:
        base_branch = os.environ.get("GIT_BASE_BRANCH")
    if not base_branch:
        print("[detect_docs_only] GIT_BASE_BRANCH is not set; full CI will run.")
        return None

    base_commit = resolve_merge_base(base_branch, runner=runner, cwd=cwd)
    if not base_commit:
        print(f"[detect_docs_only] Could not resolve merge base for {base_branch}; full CI will run.")
        return None

    changed_paths = get_changed_paths(base_commit, runner=runner, cwd=cwd)
    if changed_paths is None:
        print("[detect_docs_only] git diff failed; full CI will run.")
        return None

    if not changed_paths:
        print("[detect_docs_only] Empty diff against merge base; full CI will run.")
        return None

    docs_paths, code_paths = classify_paths(changed_paths)

    print(f"[detect_docs_only] Compared HEAD against merge base {base_commit[:10]} ({base_branch}):")
    print(f"[detect_docs_only] Total changed files: {len(changed_paths)}")
    for p in docs_paths:
        print(f"  [docs-only] {p}")
    for p in code_paths:
        print(f"  [code/exclusion] {p}")

    if code_paths:
        print(f"[detect_docs_only] Found {len(code_paths)} code/excluded file(s); full CI will run.")
        return None

    return base_commit, len(docs_paths)


def detect_docs_only(
    base_branch: str | None = None,
    marker_path: str | Path | None = None,
    event_name: str | None = None,
    runner=subprocess.run,
    cwd: str | Path | None = None,
) -> bool:
    """Determine whether the current branch is docs-only and manage marker file.

    Returns True if docs-only (marker written), False otherwise (marker removed).
    """
    if marker_path is None:
        marker_path = os.environ.get("DOCS_ONLY_MARKER", DEFAULT_MARKER_PATH)
    marker = Path(marker_path)

    # Always remove the per-run marker first so stale markers never persist into the next run.
    try:
        if marker.exists():
            marker.unlink()
    except OSError as err:
        print(f"[detect_docs_only] Warning: could not remove stale marker {marker}: {err}", file=sys.stderr)

    change = docs_only_change(base_branch=base_branch, event_name=event_name, runner=runner, cwd=cwd)
    if change is None:
        return False
    base_commit, file_count = change

    try:
        marker.parent.mkdir(parents=True, exist_ok=True)
        marker.write_text(
            f"docs-only change at HEAD\nbase={base_commit}\nfiles={file_count}\n",
            encoding="utf-8",
        )
        print(f"[detect_docs_only] Verified docs-only change ({file_count} files). Wrote {marker}.")
        print("[detect_docs_only] BazelCI gates will be skipped.")
        return True
    except OSError as err:
        print(f"[detect_docs_only] Failed to write marker {marker}: {err}; full CI will run.", file=sys.stderr)
        return False


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Detect docs-only changes in CI")
    parser.add_argument(
        "--base-branch",
        default=os.environ.get("GIT_BASE_BRANCH"),
        help="Target base branch (default: $GIT_BASE_BRANCH)",
    )
    parser.add_argument(
        "--marker",
        default=os.environ.get("DOCS_ONLY_MARKER", DEFAULT_MARKER_PATH),
        help=f"Path to marker file (default: {DEFAULT_MARKER_PATH})",
    )
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument(
        "--check",
        action="store_true",
        help="Write no marker; exit 0 for a docs-only change and 1 otherwise",
    )
    mode.add_argument(
        "--print-github-paths",
        nargs="*",
        metavar="SCOPE",
        help=(
            "Print the GitHub Actions `paths:` filter for a workflow that skips docs-only "
            "changes; pass the workflow's own path patterns, or none for a catch-all workflow"
        ),
    )
    args = parser.parse_args(argv)

    if args.print_github_paths is not None:
        for pattern in github_paths_filter(args.print_github_paths or None):
            print(f"      - '{pattern}'")
        return 0
    if args.check:
        return 0 if docs_only_change(base_branch=args.base_branch) is not None else 1

    detect_docs_only(base_branch=args.base_branch, marker_path=args.marker)
    # Always exit 0 so BuildBuddy workflow step passes and does not abort CI
    return 0


if __name__ == "__main__":
    sys.exit(main())
