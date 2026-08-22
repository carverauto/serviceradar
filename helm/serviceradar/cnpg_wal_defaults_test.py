"""Guards the CNPG WAL and checkpoint defaults.

These parameters exist because PostgreSQL's stock max_wal_size=1GB forces a
checkpoint every max_wal_size/(2 + checkpoint_completion_target) = 353MB. At this
product's ingest rate that fired a checkpoint roughly every 14 seconds, and under
load every 10 seconds, which parked every backend on LWLock:WALWrite and failed
liveness probes across an entire namespace.

The assertions below are the properties that are easy to regress silently:
  * both CNPG cluster templates are covered (spire-postgres.yaml REPLACES
    cnpg-cluster.yaml when spire.postgres.enabled, and it hosts the app database)
  * max_wal_size / min_wal_size stay DERIVED from storageSize rather than pinned,
    because pg_wal shares the data PVC and a flat value overflows small volumes
  * every injected key keeps its hasKey escape hatch
  * the unit-STRIPPING regex never comes back: it rendered a 1Ti volume as "1"
    and a bare-bytes quantity as an effectively unbounded WAL cap
"""

import os
import re
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))

STATIC_PARAMS = {
    "checkpoint_timeout": "15min",
    "checkpoint_completion_target": "0.9",
    "wal_compression": "on",
    "log_parameter_max_length": "0",
}

INJECTED = ("max_slot_wal_keep_size", "max_wal_size", "min_wal_size")

TEMPLATES = ("templates/cnpg-cluster.yaml", "templates/spire-postgres.yaml")


def read(rel):
    with open(os.path.join(HERE, rel), "r", encoding="utf-8") as handle:
        return handle.read()


class CnpgWalDefaultsTest(unittest.TestCase):
    def setUp(self):
        self.values = read("values.yaml")

    def _block(self, header, indent):
        """Return the postgresqlParameters block body at a given indent."""
        pattern = re.compile(
            r"^%s%s:\n((?:%s  .*\n|\n)*)" % (indent, header, indent), re.MULTILINE
        )
        match = pattern.search(self.values)
        self.assertIsNotNone(match, "could not find %r block in values.yaml" % header)
        return match.group(1)

    def test_static_params_present_in_both_values_blocks(self):
        # cnpg.postgresqlParameters is indented 2, spire.postgres.* is indented 4.
        for indent in ("  ", "    "):
            block = self._block("postgresqlParameters", indent)
            for key, expected in STATIC_PARAMS.items():
                self.assertIn(
                    '%s: "%s"' % (key, expected),
                    block,
                    "%s must be %r in the postgresqlParameters block at indent %d"
                    % (key, expected, len(indent)),
                )

    def test_log_parameter_max_length_is_zero_not_a_positive_cap(self):
        # The GUC truncates PER PARAMETER with no per-statement cap, so a positive
        # value does not bound the log: a 1000-row x 10-column bulk insert at 1kB
        # each still emits ~10MB for one statement. Only 0 hard-bounds it.
        for match in re.finditer(r"log_parameter_max_length:\s*\"([^\"]+)\"", self.values):
            self.assertEqual(match.group(1), "0")
        self.assertEqual(self.values.count("log_parameter_max_length:"), 2)

    def test_bind_parameters_never_logged_on_error(self):
        # Would put customer device/network data in the log on EVERY statement
        # error -- exactly when log amplification does the most damage.
        self.assertNotIn("log_parameter_max_length_on_error", self.values)

    def test_wal_sizes_stay_derived_not_pinned_in_values(self):
        # A flat value would overflow small volumes; pg_wal shares the data PVC.
        for indent in ("  ", "    "):
            block = self._block("postgresqlParameters", indent)
            self.assertNotIn("max_wal_size:", block)
            self.assertNotIn("min_wal_size:", block)

    def test_escape_hatches_declared(self):
        for key in ("maxSlotWalKeepSize", "maxWalSize", "minWalSize"):
            self.assertGreaterEqual(
                len(re.findall(r"^\s+%s:\s*\"\"\s*$" % key, self.values, re.MULTILINE)),
                2,
                "%s must be declared blank for both cnpg and spire.postgres" % key,
            )

    def test_both_templates_guard_every_injected_key(self):
        for template in TEMPLATES:
            body = read(template)
            for key in INJECTED:
                self.assertIn(
                    'hasKey (default dict $%s) "%s"'
                    % ("cnpg.postgresqlParameters" if "cnpg-cluster" in template else "postgresqlParameters", key),
                    body,
                    "%s must keep its hasKey escape hatch in %s" % (key, template),
                )
                self.assertIn('"%s":' % key, body)

    def test_unit_stripping_regex_never_returns(self):
        # regexReplaceAll "[^0-9]" STRIPS the unit instead of converting it, which
        # rendered 1Ti as "1" (collapsing the WAL cap to its 10GB floor) and is the
        # same class of bug that makes a bare-bytes quantity look unbounded.
        for template in TEMPLATES + ("templates/_helpers.tpl",):
            body = read(template)
            if template.endswith("_helpers.tpl"):
                # The helper legitimately extracts the numeric component, but only
                # after rejecting fractions and only alongside a unit conversion.
                self.assertIn('serviceradar.storageGiB', body)
                self.assertIn('1073741824', body)
                continue
            self.assertNotIn(
                'regexReplaceAll "[^0-9]"',
                body,
                "%s must convert storage units via serviceradar.storageGiB, not strip them"
                % template,
            )

    def test_bare_number_storage_is_bytes(self):
        # Bare numbers are BYTES in Kubernetes. Mapping them to GiB turns
        # storageSize: 107374182400 into an effectively unbounded WAL cap.
        helpers = read("templates/_helpers.tpl")
        self.assertRegex(
            helpers,
            r'else if eq \$unit ""\s*-\}\}\{\{-\s*\$bytes = \$n',
            "a bare-number storage quantity must be treated as bytes",
        )


if __name__ == "__main__":
    unittest.main()
