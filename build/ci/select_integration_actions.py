#!/usr/bin/env python3
"""Decide whether a BazelCI database action has any affected test on a pull request.

The BazelCI database actions (core integration, web-ng DB) each own a set of test
targets. On a pull request this script compares HEAD against its merge base with the
base branch, maps every changed file to its Bazel source label, and asks Bazel which of
the action's targets depend on any of them. When none do, it writes the action's skip
marker and the action's database lifecycle exits early.

It is conservative by construction. The action runs in full when:

  * the event is not a pull request, or the merge base or diff cannot be resolved;
  * any changed path can change the build graph or the test fixture for every target
    (see RUN_ALL_*), or was deleted;
  * a Bazel query fails.

A docs-only change (build/ci/detect_docs_only.py) skips every action, and docs paths
are excluded before the rules above, as they are for the whole BazelCI docs-only skip.
A changed file that no Bazel target references is not an input of any test, so it
affects none.
"""

from __future__ import annotations

import argparse
import os
from pathlib import Path
import subprocess
import sys
from typing import Callable, Iterable, Sequence

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    from detect_docs_only import classify_paths, get_changed_paths, resolve_merge_base
else:
    from build.ci.detect_docs_only import classify_paths, get_changed_paths, resolve_merge_base


# Targets each action executes, as Bazel query expressions: the core action runs the
# ordinary integration wildcard, the web-ng action the web-ng database suites and the Dgraph
# schema lifecycle. Compile-only manual targets are built by the unit action on every run.
_TAG = r"[\[ ]{}[,\]]"
CORE_TARGETS = (
    "attr(tags, '{integration}', tests(//...)) except attr(tags, '{excluded}', //...)"
).format(
    integration=_TAG.format("integration_test"),
    excluded="|".join(_TAG.format(tag) for tag in ("large_ingestion_test", "acceptance_test", "manual")),
)
WEB_NG_TARGETS = (
    "tests(set(//elixir/web-ng:networks_live_db_test"
    " //elixir/web-ng:topology_atlas_db_test"
    " //elixir/web-ng:plugin_config_cli_db_test"
    " //rust/dgraph-topology:schema_lifecycle_test))"
)

ACTIONS = {
    "core": (CORE_TARGETS, "/tmp/serviceradar-skip-core-integration"),
    "web_ng": (WEB_NG_TARGETS, "/tmp/serviceradar-skip-web-ng-db"),
}

# Paths that can change the build graph, external dependencies, or the shared test
# fixture of every target. Any of them runs every action.
RUN_ALL_FILES = frozenset(
    {
        ".bazelignore",
        ".bazelrc",
        ".bazelversion",
        "MODULE.bazel",
        "MODULE.bazel.lock",
        "WORKSPACE",
        "WORKSPACE.bazel",
        "WORKSPACE.bzlmod",
        "buildbuddy.yaml",
    }
)
RUN_ALL_PREFIXES = (
    "build/",
    "elixir/serviceradar_core/priv/repo/",
    "rust/integration-db/",
    "scripts/ci/",
    "third_party/",
    "tools/",
)
RUN_ALL_BASENAMES = frozenset(
    {
        "BUILD",
        "BUILD.bazel",
        "Cargo.lock",
        "bun.lock",
        "bun.lockb",
        "Cargo.toml",
        "go.mod",
        "go.sum",
        "mix.exs",
        "mix.lock",
        "package-lock.json",
        "package.json",
        "pnpm-lock.yaml",
        "pnpm-workspace.yaml",
        "yarn.lock",
    }
)

QueryRunner = Callable[[Sequence[str]], subprocess.CompletedProcess]


def run_all_reason(path: str, root: Path) -> str | None:
    """Return why a changed path forces every action to run, or None."""
    name = Path(path).name
    if path in RUN_ALL_FILES or name in RUN_ALL_BASENAMES:
        return "build or dependency definition"
    if name.endswith(".bzl"):
        return "Starlark definition"
    if path.startswith(RUN_ALL_PREFIXES):
        return "build tooling or shared fixture input"
    if not (root / path).is_file():
        return "deleted or not a regular file"
    return None


def source_label(path: str, root: Path) -> str | None:
    """Map a repository file to its source label: the nearest package that contains it."""
    parts = Path(path).parts
    for depth in range(len(parts) - 1, -1, -1):
        package = Path(*parts[:depth]) if depth else Path(".")
        if (root / package / "BUILD.bazel").is_file() or (root / package / "BUILD").is_file():
            package_name = "" if depth == 0 else package.as_posix()
            return f"//{package_name}:{Path(*parts[depth:]).as_posix()}"
    return None


def bazel_query(args: Sequence[str]) -> subprocess.CompletedProcess:
    return subprocess.run(
        ["bazel", "query", "--output=label", *args],
        capture_output=True,
        text=True,
        check=False,
    )


def existing_labels(labels: Iterable[str], query: QueryRunner) -> list[str] | None:
    """Labels Bazel knows as targets. Unreferenced files are not targets and drop out.

    Exit 0 resolves every label. Exit 3 is accepted only when Bazel reports
    "no such target" for every label missing from the output; any other error
    returns None so the action runs in full.
    """
    labels = sorted(set(labels))
    if not labels:
        return []
    result = query(["--keep_going", "set({})".format(" ".join(labels))])
    if result.returncode not in (0, 3):
        return None
    known = sorted({line.strip() for line in result.stdout.splitlines() if line.strip()})
    if result.returncode == 3:
        missing = set(labels) - set(known)
        stderr = result.stderr or ""
        if not missing or any(f"no such target '{label}'" not in stderr for label in missing):
            return None
    return known


def affected_targets(action: str, labels: Sequence[str], query: QueryRunner) -> list[str] | None:
    targets, _marker = ACTIONS[action]
    if not labels:
        return []
    expression = "let t = ({}) in $t intersect rdeps(deps($t), set({}))".format(
        targets, " ".join(labels)
    )
    result = query([expression])
    if result.returncode != 0:
        return None
    return sorted({line.strip() for line in result.stdout.splitlines() if line.strip()})


def decide(action: str, changed_paths: Sequence[str], root: Path, query: QueryRunner) -> tuple[bool, list[str]]:
    """Return (run, reasons). run=False means the action has no affected target."""
    docs, code = classify_paths(changed_paths)
    if not code:
        return False, [f"docs-only change ({len(docs)} files)"]

    forced = [
        f"{path}: {reason}"
        for path in code
        if (reason := run_all_reason(path, root)) is not None
    ]
    if forced:
        return True, forced

    labels = [label for path in code if (label := source_label(path, root)) is not None]
    known = existing_labels(labels, query)
    if known is None:
        return True, ["bazel query could not resolve the changed files"]
    affected = affected_targets(action, known, query)
    if affected is None:
        return True, ["bazel query for affected targets failed"]
    if affected:
        return True, [f"affected: {target}" for target in affected]
    return False, [f"no {action} target depends on the {len(code)} changed file(s)"]


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--action", choices=sorted(ACTIONS), required=True)
    parser.add_argument("--base-branch", default=os.environ.get("GIT_BASE_BRANCH"))
    args = parser.parse_args(argv)

    _targets, marker_path = ACTIONS[args.action]
    marker = Path(os.environ.get("SERVICERADAR_SKIP_MARKER", marker_path))
    marker.unlink(missing_ok=True)
    prefix = f"[select_integration_actions:{args.action}]"

    event = os.environ.get("BUILDBUDDY_EVENT") or os.environ.get("CI_EVENT") or os.environ.get("GITHUB_EVENT_NAME")
    if not event or event.lower() not in ("pull_request", "pr"):
        print(f"{prefix} event {event!r} is not a pull request; the action runs in full.")
        return 0
    base = resolve_merge_base(args.base_branch) if args.base_branch else None
    changed = get_changed_paths(base) if base else None
    if not changed:
        print(f"{prefix} no resolvable diff against {args.base_branch!r}; the action runs in full.")
        return 0

    run, reasons = decide(args.action, changed, Path.cwd(), bazel_query)
    for reason in reasons:
        print(f"{prefix} {reason}")
    if run:
        print(f"{prefix} the action runs in full.")
    else:
        marker.parent.mkdir(parents=True, exist_ok=True)
        marker.write_text("\n".join(reasons) + "\n", encoding="utf-8")
        print(f"{prefix} skipping the database lifecycle; wrote {marker}.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
