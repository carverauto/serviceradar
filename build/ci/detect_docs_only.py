#!/usr/bin/env python3
"""Detect docs-only changes in CI and write a skip marker.

Allows BuildBuddy BazelCI to exit early when all changes in a pull request
are documentation files, saving runner resources and speeding up CI.

Allowlist:
  docs/**
  openspec/**
  *.md (repository root only: README.md, AGENTS.md, CLAUDE.md, etc.)

Exclusions (match -> treated as code, running the full suite):
  **/BUILD
  **/BUILD.bazel
  docs/**/*.bzl
  openspec/**/*.bzl
  docs/lint_placeholder.sh
  docs/cosign.pub
  docs/sigstore/**
  openspec/changes/parallelize-core-integration-tests/benchmark.md
"""

from __future__ import annotations

import argparse
import os
from pathlib import Path
import subprocess
import sys
from typing import Iterable


DEFAULT_MARKER_PATH = "/tmp/serviceradar-docs-only-marker"


def is_allowlisted(path: str) -> bool:
    """Return True if path matches the docs allowlist.

    docs/**
    openspec/**
    *.md (repository root only; * does not cross /)
    """
    path = path.strip().lstrip("/")
    if not path:
        return False
    if path.startswith("docs/") or path.startswith("openspec/"):
        return True
    if "/" not in path and path.endswith(".md"):
        return True
    return False


def is_excluded(path: str) -> bool:
    """Return True if path matches an exclusion requiring a full build/test run."""
    path = path.strip().lstrip("/")
    filename = Path(path).name
    if filename in ("BUILD", "BUILD.bazel"):
        return True
    if (path.startswith("docs/") or path.startswith("openspec/")) and path.endswith(".bzl"):
        return True
    if path == "docs/lint_placeholder.sh":
        return True
    if path == "docs/cosign.pub":
        return True
    if path.startswith("docs/sigstore/"):
        return True
    if path == "openspec/changes/parallelize-core-integration-tests/benchmark.md":
        return True
    return False


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

    # Check event if specified / set in environment
    if event_name is None:
        event_name = (
            os.environ.get("BUILDBUDDY_EVENT")
            or os.environ.get("CI_EVENT")
            or os.environ.get("GITHUB_EVENT_NAME")
        )
    if event_name and event_name.lower() not in ("pull_request", "pr"):
        print(f"[detect_docs_only] Event '{event_name}' is not a pull_request; full CI will run.")
        return False

    if not base_branch:
        base_branch = os.environ.get("GIT_BASE_BRANCH")
    if not base_branch:
        print("[detect_docs_only] GIT_BASE_BRANCH is not set; full CI will run.")
        return False

    base_commit = resolve_merge_base(base_branch, runner=runner, cwd=cwd)
    if not base_commit:
        print(f"[detect_docs_only] Could not resolve merge base for {base_branch}; full CI will run.")
        return False

    changed_paths = get_changed_paths(base_commit, runner=runner, cwd=cwd)
    if changed_paths is None:
        print("[detect_docs_only] git diff failed; full CI will run.")
        return False

    if not changed_paths:
        print("[detect_docs_only] Empty diff against merge base; full CI will run.")
        return False

    docs_paths, code_paths = classify_paths(changed_paths)

    print(f"[detect_docs_only] Compared HEAD against merge base {base_commit[:10]} ({base_branch}):")
    print(f"[detect_docs_only] Total changed files: {len(changed_paths)}")
    for p in docs_paths:
        print(f"  [docs-only] {p}")
    for p in code_paths:
        print(f"  [code/exclusion] {p}")

    if code_paths:
        print(f"[detect_docs_only] Found {len(code_paths)} code/excluded file(s); full BazelCI suite will run.")
        return False

    # All files are docs-only!
    try:
        marker.parent.mkdir(parents=True, exist_ok=True)
        marker.write_text(
            f"docs-only change at HEAD\nbase={base_commit}\nfiles={len(docs_paths)}\n",
            encoding="utf-8",
        )
        print(f"[detect_docs_only] Verified docs-only change ({len(docs_paths)} files). Wrote {marker}.")
        print("[detect_docs_only] BazelCI gates will be skipped.")
        return True
    except OSError as err:
        print(f"[detect_docs_only] Failed to write marker {marker}: {err}; full CI will run.", file=sys.stderr)
        return False


def main() -> int:
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
    args = parser.parse_args()

    detect_docs_only(base_branch=args.base_branch, marker_path=args.marker)
    # Always exit 0 so BuildBuddy workflow step passes and does not abort CI
    return 0


if __name__ == "__main__":
    sys.exit(main())
