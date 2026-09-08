"""Keep ordinary reaper SQL mirrored and the whole template namespace reserved.

This is a source contract, not a PostgreSQL integration test. No live database or
deployment data is used. The intentionally narrow parser accepts the checked-in
literal YAML block and fails if that representation changes.
"""

import re
import unittest
from pathlib import Path

K8S = Path(__file__).resolve().parents[1]


def embedded_sql(yaml):
    blocks = re.findall(r"^  reap\.sql: \|\n((?:    [^\n]*\n|\n)+)", yaml, re.M)
    if len(blocks) != 1:
        raise AssertionError("expected exactly one literal reap.sql YAML block")
    return "\n".join(line[4:] for line in blocks[0].splitlines())


def executable_sql(sql):
    # Only discard full comment lines. Inline comments and quoted contents stay
    # significant so normalization cannot hide a changed predicate or literal.
    lines = (line for line in sql.splitlines() if not line.lstrip().startswith("--"))
    return " ".join(re.findall(r"'(?:''|[^'])*'|[^\s']+", "\n".join(lines)))


def excluded_namespace(sql):
    # Both deployed spellings are literal prefix checks (SQL LIKE underscores
    # would be wildcards). Reject digest-only guards and OR/conditional suffixes.
    guards = re.findall(
        r"^\s*AND (?:d\.datname !~ '(\^sr_tpl_)'|"
        r"left\(d\.datname, 7\) <> '(sr_tpl_)')\s*$",
        "\n".join(line for line in sql.splitlines() if not line.lstrip().startswith("--")),
        re.M,
    )
    if len(guards) != 1:
        raise AssertionError("expected one unconditional exclusion of the entire sr_tpl_ prefix")
    pattern, prefix = guards[0]
    return lambda name: bool(re.search(pattern, name)) if pattern else name[:7] == prefix


class ScratchReaperContract(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.standalone = (K8S / "scratch-reaper.sql").read_text()
        cls.embedded = embedded_sql((K8S / "scratch-reaper.yaml").read_text())

    def test_yaml_mirrors_standalone_executable_sql(self):
        self.assertEqual(
            executable_sql(self.standalone),
            executable_sql(self.embedded),
            "ConfigMap reap.sql must mirror scratch-reaper.sql (comments/whitespace may differ)",
        )

    def test_both_queries_exclude_all_reserved_names(self):
        generation = "sr_tpl_" + "0123abcd" * 6
        reserved = (
            generation, generation + "_c12345", generation + "_1234567",
            "sr_tpl_", "sr_tpl_short", "sr_tpl_" + "z" * 48,
            generation + "_overlong_candidate", "sr_tpl_has space", 'sr_tpl_has"quote',
        )
        scratch = ("sr_tpl", "srXtpl_example", "sr_tplx_example", "scratch_sr_tpl_example")
        for source in (self.standalone, self.embedded):
            excludes = excluded_namespace(source)
            for name in reserved:
                with self.subTest(name=name):
                    self.assertTrue(excludes(name), "reserved name escaped the exclusion")
            for name in scratch:
                with self.subTest(name=name):
                    self.assertFalse(excludes(name), "prefix exclusion overmatched scratch name")

    def test_contract_rejects_weakened_guards(self):
        for guard in (
            "-- AND d.datname !~ '^sr_tpl_'",
            "AND d.datname !~ '^sr_tpl_[0-9a-f]{48}$'",
            "AND d.datname NOT LIKE 'sr_tpl_%'",
            "AND left(d.datname, 7) <> 'sr_tpl_' OR true",
            "",
        ):
            with self.subTest(guard=guard), self.assertRaises(AssertionError):
                excluded_namespace(guard)


if __name__ == "__main__":
    unittest.main()
