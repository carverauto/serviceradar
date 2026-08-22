#!/usr/bin/env python3
"""Every component that renders a workload must be gateable, and its gate must be default-safe.

Issue #3859: most of this chart's components had no `enabled` gate at all, so setting
`<component>.enabled: false` was a SILENT NO-OP -- the workload deployed anyway while the values
file read as though it had been turned off. A values file that lies is worse than an unsupported
option, because the next reader believes it.

This test DERIVES the component list from the templates rather than restating it. A new component
that renders a Deployment or StatefulSet fails here until it is gated, which is the only way the
two stay in step: a hand-written list is exactly what drifted in the first place.

## The failure modes it covers

1. NO GATE, or a gate that does not WRAP the resources. Position matters: an earlier version of
   this test searched the whole file for the word `enabled`, and a mutation that replaced a real
   gate with `{{- if true }}` SURVIVED it, because inner feature flags further down still
   matched. The gate must appear before the first `kind:` and the file must close it.

2. A GATE WHOSE DEFAULT IS UNSTATED. `{{- if $x.enabled }}` is falsy when the key is ABSENT, so
   the chart's own values.yaml must state the default rather than leave it implied. Either value
   is correct -- `true` for a component that ships on, `false` for an opt-in one like gobgp --
   but an unstated default makes behaviour depend on what an operator happens to omit. The
   `hasKey` form carries no such requirement: absent means enabled by construction.

3. `default true`. Helm treats `false` as empty, so `default true $x.enabled` returns TRUE for an
   explicitly disabled component and resurrects it. Such a flag cannot turn anything off.
"""

from pathlib import Path
import re
import unittest

CHART_DIR = Path(__file__).resolve().parent
TEMPLATES = CHART_DIR / "templates"
VALUES = CHART_DIR / "values.yaml"

WORKLOAD = re.compile(r"^kind:\s*(Deployment|StatefulSet)\s*$", re.M)

# `{{- if or (not (hasKey $gate0 "enabled")) $gate0.enabled }}` -- absent means enabled.
HASKEY_GATE = re.compile(r'hasKey\s+\$(\w+)\s+"enabled"')

# `{{- if $gateway.enabled -}}` / `{{- if .Values.foo.enabled }}` -- absent means DISABLED.
VAR_GATE = re.compile(r"\{\{-?\s*if\s+\$(\w+)\.enabled")
VALUES_GATE = re.compile(r"\{\{-?\s*if\s+\.Values\.(\w+)\.enabled")

# `{{- $gateway := default (dict) .Values.agentGateway -}}` -- resolve a gate var to its key.
VAR_BINDING = r"\$%s\s*:=[^\n]*\.Values\.(\w+)"


class ComponentGatesTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.values = VALUES.read_text(encoding="utf-8")
        cls.workloads = {}

        for path in sorted(TEMPLATES.glob("*.yaml")):
            text = path.read_text(encoding="utf-8")
            if WORKLOAD.search(text):
                cls.workloads[path.name] = text

    def test_the_chart_still_has_workloads_to_check(self):
        # NOT VACUOUS. If the glob or the workload pattern stopped matching, every assertion
        # below would pass over an empty set and report success while checking nothing.
        self.assertGreater(
            len(self.workloads),
            10,
            f"only {len(self.workloads)} workload templates found; the detection is broken, "
            "not the chart",
        )

    def test_every_workload_template_is_gated(self):
        ungated = []

        for name, text in self.workloads.items():
            gate = self._gate_index(text)
            first_kind = self._first_kind_index(text)

            if gate is None or first_kind is None or gate > first_kind:
                ungated.append(name)
            elif not text.rstrip().endswith("{{- end }}"):
                ungated.append(name + " (gate opened but never closed)")

        self.assertEqual(
            [],
            ungated,
            "these templates render a workload that no `enabled` gate wraps, so "
            "`<component>.enabled: false` is a silent no-op for them (issue #3859): "
            + ", ".join(ungated),
        )

    def test_a_gate_that_defaults_to_off_states_its_default(self):
        offenders = []

        for name, text in self.workloads.items():
            if HASKEY_GATE.search(text):
                continue

            key = self._gate_key(text)
            if key is None:
                continue

            if not self._values_states_default(key):
                offenders.append(f"{name} (gates on {key}.enabled)")

        self.assertEqual(
            [],
            offenders,
            "these gates are falsy when the key is absent, and values.yaml does not state a "
            "default for them, so the behaviour depends on what an operator omits: "
            + ", ".join(offenders),
        )

    def test_no_component_gate_uses_default_true(self):
        # SCOPED TO THE COMPONENT'S OWN GATE, deliberately. The chart uses `default true` for
        # about thirty SUB-FEATURE flags as well -- network-policy ports, pod disruption
        # budgets, core.migrations, cnpg -- and every one of those is inert the same way. That
        # is a real defect and a larger change, reaching network policy and PDB rendering, so it
        # is reported separately rather than folded in here. This holds the line where the gates
        # were just added so the count cannot grow while that is outstanding.
        for name, text in self.workloads.items():
            gate = self._gate_line(text)
            if gate is None:
                continue

            self.assertNotRegex(
                gate,
                r"default\s+true",
                f"{name}'s component gate uses `default true`, which resurrects an explicitly "
                "disabled component because Helm treats false as empty",
            )

    def _gate_index(self, text):
        for i, line in enumerate(text.splitlines()):
            if re.search(r"\{\{-?\s*if\b", line) and ".enabled" in line:
                return i
        return None

    def _gate_line(self, text):
        i = self._gate_index(text)
        return None if i is None else text.splitlines()[i]

    def _first_kind_index(self, text):
        for i, line in enumerate(text.splitlines()):
            if re.match(r"^kind:\s*\w+", line):
                return i
        return None

    def _gate_key(self, text):
        m = VALUES_GATE.search(text)
        if m:
            return m.group(1)

        m = VAR_GATE.search(text)
        if not m:
            return None

        binding = re.search(VAR_BINDING % re.escape(m.group(1)), text)
        return binding.group(1) if binding else None

    def _values_states_default(self, key):
        block = re.search(
            rf"^{re.escape(key)}:\n((?:[ \t]+[^\n]*\n|\n)*)", self.values, re.M
        )
        return bool(block) and re.search(
            r"^\s+enabled:\s*(true|false)\s*$", block.group(1), re.M
        )


if __name__ == "__main__":
    unittest.main()
