"""Runs the chart's helm-unittest suite (helm/serviceradar/tests/*_test.yaml).

This target exists because `helm unittest` was wired into NO CI job. The suite rotted
unobserved: 26 assertions across 10 suites were committed having never once been
executed, and every one of them had been written by reading `helm template` output
rather than by running the plugin -- they asserted Helm's kind-sorted document order
(the plugin indexes documents in raw template order) and a `default` release namespace
(the plugin's default is the literal "NAMESPACE"). `helm lint`, the only helm job in
CI, does not execute assertions and stayed green throughout.

Two failure modes are therefore gated here, not one:

  1. an assertion goes red, and
  2. a NEW suite file is added but never actually runs.

(2) is the one that let this happen. The suite count below is derived from the
`tests/*_test.yaml` files present in runfiles and compared against what the plugin
reports it executed, so a suite that the glob misses -- or that the plugin silently
skips -- fails loudly instead of passing by omission.

The runner is the plugin's `untt` binary invoked directly rather than via
`helm unittest`. That is the same code path (plugin.yaml declares
`command: "$HELM_PLUGIN_DIR/untt"` with ignoreFlags false, so helm only execs it), it
needs no helm binary and no HELM_PLUGINS staging, and it keeps the gate off
get.helm.sh, which the BuildBuddy runners cannot reach.
"""

import os
import pathlib
import re
import subprocess
import sys
import unittest


def _runfile(env_var):
    raw = os.environ[env_var]
    path = pathlib.Path(raw).resolve()
    if not path.exists():
        raise AssertionError(f"{env_var}={raw} does not exist (resolved {path})")
    return path


class HelmUnittestSuiteTest(unittest.TestCase):
    def test_chart_unit_suite_passes(self):
        chart_dir = _runfile("SERVICERADAR_CHART_YAML").parent
        untt = _runfile("SERVICERADAR_HELM_UNITTEST_BINARY")

        suites = sorted(chart_dir.glob("tests/*_test.yaml"))
        self.assertTrue(
            suites,
            f"no tests/*_test.yaml reached runfiles under {chart_dir}; the py_test data "
            "glob is wrong and this target would otherwise pass while testing nothing",
        )

        # Drop every inherited HELM_* var. untt ignores the ones that matter today, but
        # a developer's HELM_NAMESPACE deciding whether CI is green is not a property
        # worth having -- the suites that care pin `release.namespace` themselves.
        env = {k: v for k, v in os.environ.items() if not k.startswith("HELM_")}
        env["HOME"] = os.environ.get("TEST_TMPDIR", "/tmp")

        proc = subprocess.run(
            [str(untt), str(chart_dir)],
            capture_output=True,
            text=True,
            env=env,
        )
        output = proc.stdout + proc.stderr
        self.assertEqual(
            proc.returncode,
            0,
            f"helm-unittest failed (exit {proc.returncode}):\n{output}",
        )

        match = re.search(
            r"^Test Suites:\s+(?:(\d+) failed, )?(\d+) passed, (\d+) total\s*$",
            output,
            re.M,
        )
        self.assertIsNotNone(
            match, f"could not parse the helm-unittest summary from:\n{output}"
        )
        failed, passed, total = match.group(1), int(match.group(2)), int(match.group(3))
        self.assertIsNone(failed, f"helm-unittest reported failed suites:\n{output}")
        self.assertEqual(passed, total, f"not every suite passed:\n{output}")
        # The guard that would have caught the original rot: a suite file that never runs.
        self.assertEqual(
            total,
            len(suites),
            "helm-unittest executed "
            f"{total} suite(s) but {len(suites)} tests/*_test.yaml file(s) are present: "
            f"{[s.name for s in suites]}\n{output}",
        )


if __name__ == "__main__":
    sys.exit(unittest.main())
