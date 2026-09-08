#!/usr/bin/env python3
"""Run a compiled Go test binary's benchmarks and fail if it ran none.

Go benchmarks do not run under `go test` -- or `bazel test` -- without `-test.bench`. A
`Benchmark*` function therefore compiles, passes review, appears in a file listing, and rots,
while the package's tests stay green. That is what this runner exists to stop.

## Why it checks that benchmarks actually RAN

`go test -bench=nonexistent` exits 0. A filter that matches nothing and a run that measures
nothing produce the same successful exit, so a benchmark target that only checked the exit code
would report success while executing nothing -- the same defect one level up. This asserts at
least one `Benchmark...` result line came back.

## What it deliberately does NOT do

It does not compare against a threshold. A benchmark on a shared CI runner is noisy, and a
threshold set before that variance is measured produces failures that are not regressions; the
predictable response is to mute the check, and a muted gate still looks like protection. Results
are printed for collection, and gating is a later decision made from data.
"""

import argparse
import os
import re
import subprocess
import sys

# `BenchmarkChecksum_64B-10   	 1000000	      1053 ns/op`
RESULT = re.compile(r"^Benchmark\S*\s+\d+\s+", re.M)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", required=True, help="compiled go_test binary to run")
    parser.add_argument(
        "--benchtime",
        default="1x",
        help="Go -test.benchtime. Defaults to a single iteration: CI runs this for ROT, "
        "not for numbers stable enough to compare.",
    )
    parser.add_argument("--filter", default=".", help="Go -test.bench regexp")
    parser.add_argument(
        "--kind",
        default="go",
        choices=("go", "plain"),
        help="`go` drives a Go test binary's benchmarks; `plain` runs a standalone bench "
        "program (Cargo `harness = false`) that takes no filter and has its own main.",
    )
    args = parser.parse_args()

    binary = args.binary
    if not os.path.isabs(binary):
        binary = os.path.join(os.getcwd(), binary)

    if not os.path.exists(binary):
        print(f"benchmark binary not found: {binary}", file=sys.stderr)
        return 1

    if args.kind == "plain":
        return run_plain(binary)

    cmd = [
        binary,
        f"-test.bench={args.filter}",
        f"-test.benchtime={args.benchtime}",
        # Run ONLY benchmarks. Without this the package's ordinary tests run too, and a
        # failure there would be reported as a benchmark failure.
        "-test.run=^$",
        "-test.benchmem",
    ]

    proc = subprocess.run(cmd, capture_output=True, text=True, check=False)
    output = proc.stdout + proc.stderr
    print(output)

    if proc.returncode != 0:
        print(f"benchmark binary exited {proc.returncode}", file=sys.stderr)
        return proc.returncode

    matches = RESULT.findall(output)
    if not matches:
        print(
            f"NO BENCHMARK RAN. `-test.bench={args.filter}` matched nothing in {binary}, and Go "
            "exits 0 when a filter matches nothing -- so without this check the target would "
            "report success while measuring nothing.",
            file=sys.stderr,
        )
        return 1

    print(f"ran {len(matches)} benchmark(s)")
    return 0


def run_plain(binary):
    """A standalone bench program: it runs, exits 0, and reports something.

    There is no filter to match and no result format to parse, so the check is weaker than the
    Go one by necessity. It still rules out the failure that matters: a benchmark that produced
    NO output is indistinguishable from one that did no work.
    """
    proc = subprocess.run([binary], capture_output=True, text=True, check=False)
    output = proc.stdout + proc.stderr
    print(output)

    if proc.returncode != 0:
        print(f"benchmark exited {proc.returncode}", file=sys.stderr)
        return proc.returncode

    if not output.strip():
        print(
            f"{binary} exited 0 but printed NOTHING, so there is no evidence it measured "
            "anything.",
            file=sys.stderr,
        )
        return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())
