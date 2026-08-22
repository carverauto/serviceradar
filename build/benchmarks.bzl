"""Bazel targets that RUN benchmarks, rather than only compiling them.

`bazel test` compiles a Go `Benchmark*` function and then skips it: benchmarks need
`-test.bench`, which no target passed. So a benchmark could rot indefinitely while its package's
tests stayed green -- it looked like coverage and measured nothing.

`go_benchmark` wraps an existing `go_test` binary and runs its benchmarks. It is a separate
target from the correctness test on purpose: a slow benchmark must never delay the unit sweep,
and a benchmark failure must not read as a test failure.

NO THRESHOLD, DELIBERATELY. These record numbers; they do not gate. A benchmark on a shared CI
runner is noisy, and a threshold set before that variance is measured produces failures that are
not regressions -- the predictable response is to mute the check, and a muted gate still looks
like protection. Gating is a later decision, argued from collected data.
"""

load("@rules_python//python:defs.bzl", "py_test")

def go_benchmark(name, binary, benchtime = "1x", filter = ".", tags = None, **kwargs):
    """Runs the benchmarks in a compiled go_test binary.

    Args:
      name: target name.
      binary: a `go_test` target whose package declares `Benchmark*` functions.
      benchtime: Go's `-test.benchtime`. Defaults to `1x` -- ONE iteration. CI runs these to
        prove they still work, not to produce numbers stable enough to compare, and a default
        that took seconds per benchmark would make the sweep the reason nobody runs it.
      filter: Go's `-test.bench` regexp.
      tags: extra tags. `benchmark` is always added so an invocation can select or exclude them.
      **kwargs: forwarded to py_test.
    """
    py_test(
        name = name,
        srcs = ["//build:benchmark_runner.py"],
        main = "//build:benchmark_runner.py",
        args = [
            "--binary=$(rootpath %s)" % binary,
            "--benchtime=%s" % benchtime,
            "--filter=%s" % filter,
        ],
        data = [binary],
        # `benchmark` selects them; `no-remote-exec` is NOT set -- these measure relative cost
        # on whatever machine runs them, and they are not gated, so executor variance is
        # recorded rather than fatal.
        tags = (tags or []) + ["benchmark"],
        **kwargs
    )

def rust_benchmark(name, binary, tags = None, **kwargs):
    """Runs a standalone Rust bench binary and fails if it exits non-zero or prints nothing.

    The netprobe benches declare `harness = false` in Cargo.toml, so each is an ordinary program
    with its own `main` rather than a criterion harness. There is no `-bench` filter to pass and
    no result-line format to match: the contract is simply that it runs, exits 0, and reports
    something. A benchmark that printed nothing would be indistinguishable from one that did no
    work, which is the same hazard the Go runner guards with its result-line check.

    Args:
      name: target name.
      binary: a `rust_binary` built from a `benches/*.rs` entry point.
      tags: extra tags; `benchmark` is always added.
      **kwargs: forwarded to py_test.
    """
    py_test(
        name = name,
        srcs = ["//build:benchmark_runner.py"],
        main = "//build:benchmark_runner.py",
        args = [
            "--binary=$(rootpath %s)" % binary,
            "--kind=plain",
        ],
        data = [binary],
        tags = (tags or []) + ["benchmark"],
        **kwargs
    )
