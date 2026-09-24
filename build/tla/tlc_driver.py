"""Runs TLC on one spec/config pair and judges the result against an expectation.

Used by the tlc_test macro in //build/tla:tlc.bzl. The judgement uses TLC's exit status AND
the line naming the violated property, because either alone is ambiguous: exit 12 is any
invariant, and a config error also prints lines starting with "Error:". The exact lines
below were captured from TLC 1.7.4 (TLC2 2.19); see openspec/changes/add-dire-formal-model.
"""

import argparse
import os
import re
import shutil
import subprocess
import sys

SUCCESS_LINE = "Model checking completed. No error has been found."
EXIT_OK = 0
EXIT_INVARIANT_VIOLATED = 12
EXIT_ACTION_PROPERTY_VIOLATED = 13
VIOLATION_EXITS = (EXIT_INVARIANT_VIOLATED, EXIT_ACTION_PROPERTY_VIOLATED)

_VIOLATION_RE = re.compile(
    r"^Error: (?:Invariant|Action property) (\S+) is violated\.$", re.MULTILINE
)
_EXPECT_RE = re.compile(r"^(pass|violation:([A-Za-z][A-Za-z0-9_]*))$")


def parse_expect(expect):
    match = _EXPECT_RE.match(expect)
    if not match:
        raise ValueError(
            f"expect must be 'pass' or 'violation:<Property>', got {expect!r}"
        )
    if match.group(1) == "pass":
        return ("pass", None)
    return ("violation", match.group(2))


def judge(exit_code, output, expect):
    kind, prop = parse_expect(expect)
    violated = _VIOLATION_RE.findall(output)

    if kind == "pass":
        if exit_code != EXIT_OK:
            detail = f"; violated {', '.join(violated)}" if violated else ""
            return (False, f"expected pass, TLC exited {exit_code}{detail}")
        if SUCCESS_LINE not in output:
            return (False, "expected pass, TLC exited 0 without the success line")
        return (True, "TLC found no error")

    if exit_code not in VIOLATION_EXITS:
        if exit_code == EXIT_OK:
            return (False, f"expected violation of {prop}, TLC found no violation")
        return (False, f"expected violation of {prop}, TLC exited {exit_code}")
    if violated != [prop]:
        found = ", ".join(violated) if violated else "none"
        return (False, f"expected violation of {prop}, TLC reported: {found}")
    return (True, f"TLC reported the expected violation of {prop}")


def _rlocation(path):
    from python.runfiles import runfiles

    resolved = runfiles.Create().Rlocation(path)
    if not resolved or not os.path.exists(resolved):
        raise FileNotFoundError(f"runfile not found: {path}")
    return resolved


def main(argv):
    parser = argparse.ArgumentParser()
    parser.add_argument("--tlc", required=True)
    parser.add_argument("--spec", required=True)
    parser.add_argument("--cfg", required=True)
    parser.add_argument("--dep", action="append", default=[])
    parser.add_argument("--expect", required=True)
    parser.add_argument("--workers", type=int, default=1)
    parser.add_argument("--check-deadlock", action="store_true")
    args = parser.parse_args(argv)
    parse_expect(args.expect)

    tmp = os.environ.get("TEST_TMPDIR") or os.path.abspath("tlc_tmp")
    model_dir = os.path.join(tmp, "model")
    java_tmp = os.path.join(tmp, "java")
    os.makedirs(model_dir, exist_ok=True)
    os.makedirs(java_tmp, exist_ok=True)

    # TLC resolves EXTENDS relative to the spec's directory, and runfiles may be
    # read-only, so the spec, config and dependency modules are copied together.
    for rpath in [args.spec, args.cfg, *args.dep]:
        shutil.copy(_rlocation(rpath), model_dir)

    command = [
        _rlocation(args.tlc),
        f"--jvm_flag=-Djava.io.tmpdir={java_tmp}",
        "-workers", str(args.workers),
        "-metadir", os.path.join(tmp, "states"),
        "-config", os.path.basename(args.cfg),
    ]
    if not args.check_deadlock:
        command.append("-deadlock")  # -deadlock DISABLES deadlock checking
    command.append(os.path.basename(args.spec))

    proc = subprocess.run(
        command, cwd=model_dir, capture_output=True, text=True, check=False
    )
    output = proc.stdout + proc.stderr
    ok, reason = judge(proc.returncode, output, args.expect)
    print(output)
    print(("PASS: " if ok else "FAIL: ") + reason)
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
