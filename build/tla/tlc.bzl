"""tlc_test: model check one TLA+ spec/config pair with TLC as a Bazel test.

expect = "pass" requires TLC to finish with no error. expect = "violation:<Property>"
requires TLC to report exactly that invariant or action property violated; a different
property, a pass, or a config error all fail. See openspec/changes/add-dire-formal-model.
"""

load("@rules_python//python:py_test.bzl", "py_test")

_TLC = "//build/tla:tlc"
_DRIVER = "//build/tla:tlc_driver.py"

def _check_expect(expect):
    if expect == "pass":
        return
    if not expect.startswith("violation:") or len(expect) == len("violation:"):
        fail("tlc_test expect must be 'pass' or 'violation:<Property>', got %r" % expect)

def tlc_test(name, spec, cfg, deps = [], expect = "pass", workers = 1, check_deadlock = False, size = "small", **kwargs):
    _check_expect(expect)
    tags = kwargs.pop("tags", []) + ["tlc"]
    args = [
        "--tlc=$(rlocationpath %s)" % _TLC,
        "--spec=$(rlocationpath %s)" % spec,
        "--cfg=$(rlocationpath %s)" % cfg,
        "--expect=%s" % expect,
        "--workers=%d" % workers,
    ] + ["--dep=$(rlocationpath %s)" % dep for dep in deps]
    if check_deadlock:
        args.append("--check-deadlock")

    py_test(
        name = name,
        size = size,
        srcs = [_DRIVER],
        main = _DRIVER,
        args = args,
        data = [_TLC, spec, cfg] + deps,
        deps = ["//build/tla:tlc_driver_lib"],
        tags = tags,
        **kwargs
    )
