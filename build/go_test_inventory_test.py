#!/usr/bin/env python3
"""Fail when a `*_test.go` file exists that its package's `go_test` target does not list.

## Why this exists

`go test ./...` DISCOVERS test files; a Bazel `go_test` target ENUMERATES them. Replacing the
former with the latter therefore trades a slow, always-complete run for a fast, silently
incomplete one: a new `foo_test.go` compiles under `go test`, runs, and gates -- and under Bazel
it simply is not in `srcs`, so nothing runs it and nothing says so.

That is not hypothetical for this repo. The Elixir side has already been bitten twice by the same
shape, where a test file existed but no target named it, so it was ungated until someone
remembered. Gazelle would keep these lists current, but it does not run here, so the guard is the
thing that makes enumeration safe.

## Scope, stated honestly

This covers the packages whose `go test ./...` auto-discovery was removed when the edge ABI suites
moved to Bazel. The same enumeration gap exists repo-wide and predates that move; widening this
guard to every Go package is worthwhile follow-up, not something this pass claims to have done.

Build-tagged test files would need care -- a file behind `//go:build sometag` is legitimately
absent from the default `srcs` -- but none of the covered packages has one today, and the guard
fails loudly rather than guessing if that changes.
"""

import os
import re
import sys

# (package directory, go_test target name). The BUILD file is always BUILD.bazel in that dir.
COVERED = [
    ("proto/edge/v1", "edgev1_golden_test"),
    ("go/pkg/edge/edgerecord", "edgerecord_test"),
    ("go/pkg/edge/execstate", "execstate_test"),
    ("go/pkg/edge/projection", "projection_test"),
]

SRCS_BLOCK = re.compile(r"srcs\s*=\s*\[(.*?)\]", re.S)
QUOTED = re.compile(r'"([^"]+)"')


def go_test_srcs(build_text, target):
    """The `srcs` list of one `go_test` target, or None when the target is absent."""
    # Find the go_test( ... ) call whose name matches, without a full Starlark parse: the
    # rule name appears within the first few lines of the call.
    for match in re.finditer(r"go_test\(", build_text):
        start = match.start()
        depth = 0
        for i in range(start, len(build_text)):
            if build_text[i] == "(":
                depth += 1
            elif build_text[i] == ")":
                depth -= 1
                if depth == 0:
                    call = build_text[start : i + 1]
                    break
        else:
            continue

        name = re.search(r'name\s*=\s*"([^"]+)"', call)
        if not name or name.group(1) != target:
            continue

        srcs = SRCS_BLOCK.search(call)
        return set(QUOTED.findall(srcs.group(1))) if srcs else set()

    return None


def main():
    root = os.environ.get("BUILD_WORKSPACE_DIRECTORY") or os.getcwd()
    failures = []

    for pkg, target in COVERED:
        pkg_dir = os.path.join(root, pkg)
        build_path = os.path.join(pkg_dir, "BUILD.bazel")

        if not os.path.isdir(pkg_dir):
            failures.append(f"{pkg}: package directory not found")
            continue

        if not os.path.isfile(build_path):
            failures.append(f"{pkg}: BUILD.bazel not found")
            continue

        with open(build_path, encoding="utf-8") as handle:
            listed = go_test_srcs(handle.read(), target)

        if listed is None:
            failures.append(f"{pkg}: no go_test target named {target}")
            continue

        on_disk = {f for f in os.listdir(pkg_dir) if f.endswith("_test.go")}

        # NOT VACUOUS: a package with no test files would compare two empty sets and pass while
        # proving nothing, so an empty directory is itself a failure.
        if not on_disk:
            failures.append(f"{pkg}: no *_test.go files found; the guard would prove nothing")
            continue

        missing = sorted(on_disk - listed)
        if missing:
            failures.append(
                f"{pkg}: {len(missing)} test file(s) exist but are not in {target} srcs, "
                f"so NOTHING RUNS THEM: {', '.join(missing)}"
            )

        # A listed file that does not exist breaks the build rather than hiding a test, but it
        # means the list is stale, and a stale list is how the first kind of drift starts.
        stale = sorted(listed - on_disk)
        if stale:
            failures.append(f"{pkg}: {target} lists files that do not exist: {', '.join(stale)}")

    if failures:
        print("Go test inventory drift:\n", file=sys.stderr)
        for failure in failures:
            print(f"  - {failure}", file=sys.stderr)
        print(
            "\n`go test ./...` discovered these automatically; a go_test target does not. "
            "Add the file to srcs, or the package is silently ungated.",
            file=sys.stderr,
        )
        return 1

    covered = ", ".join(pkg for pkg, _ in COVERED)
    print(f"go_test srcs match the *_test.go files on disk for: {covered}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
