"""Synthetic schema contracts: never require a fixture database or captured SQL."""

import copy
import hashlib
import json
from pathlib import Path
import tempfile
import unittest

from build.schema_template.manifest import (
    COVERED_DOMAIN,
    GROUPS,
    build_manifest,
    canonical_json,
    input_digest,
    main,
)


class ManifestTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.groups = {group: [] for group in GROUPS}
        self.add("migration", "repo/migrations/20_add_item.exs", b"create table(:item)\n")
        self.add("migration", "repo/migrations/10_init.exs", b"create table(:sample)\n")
        self.add("baseline-sql", "repo/baseline/schema.sql", b"CREATE TABLE sample (id integer);\n")
        self.metadata = {
            "version": 1,
            "schema_file": "schema.sql",
            "schema_sha256": hashlib.sha256(self.read("baseline-sql")).hexdigest(),
            "included_through": 10,
            "postgres_major": 18,
        }
        self.add("baseline-metadata", "repo/baseline/metadata.json", canonical_json(self.metadata))
        self.add("helper", "repo/lib/bootstrap.ex", b"defmodule Bootstrap do\nend\n")
        self.add("construction", "repo/mix.lock", b'%{"ecto_sql": "synthetic-version"}\n')
        self.add("construction", "build/schema_template/policy.json", b'{"construction_mode":"full_replay"}')

    def add(self, group, logical, data):
        physical = self.root / str(sum(map(len, self.groups.values())))
        physical.write_bytes(data)
        self.groups[group].append((logical, physical))

    def read(self, group, index=0):
        return self.groups[group][index][1].read_bytes()

    def write_metadata(self):
        self.groups["baseline-metadata"][0][1].write_bytes(canonical_json(self.metadata))

    def test_order_and_checkout_independence(self):
        expected = canonical_json(build_manifest(self.groups))
        moved = {}
        for group, entries in reversed(list(self.groups.items())):
            moved[group] = []
            for logical, path in reversed(entries):
                destination = self.root / ("relocated-" + path.name)
                destination.write_bytes(path.read_bytes())
                moved[group].append((logical, destination))
        self.assertEqual(expected, canonical_json(build_manifest(moved)))
        result = json.loads(expected)
        self.assertEqual(result["migration_versions"], [10, 20])
        self.assertEqual([item["path"] for item in result["inputs"]], sorted(item["path"] for item in result["inputs"]))
        self.assertEqual(result["database"], "sr_tpl_" + result["digest"][:48])
        self.assertEqual(len(result["database"]), 55)

    def test_wire_encoding_without_json(self):
        item = {"path": "a", "sha256": "ab" * 32}
        preimage = b"serviceradar.schema-template.v1\0" + b"\0" * 7 + b"\1" + b"\0" * 7 + b"\1a" + bytes.fromhex("ab" * 32)
        self.assertEqual(input_digest([item]), hashlib.sha256(preimage).hexdigest())
        self.assertNotEqual(input_digest([item]), input_digest([item], COVERED_DOMAIN))

    def test_same_version_edit_invalidates_identity(self):
        before = build_manifest(self.groups)
        path = self.groups["migration"][1][1]
        path.write_bytes(path.read_bytes() + b"alter table(:sample)\n")
        after = build_manifest(self.groups)
        self.assertEqual(before["migration_versions"], after["migration_versions"])
        self.assertNotEqual(before["digest"], after["digest"])
        self.assertNotEqual(before["covered_migrations"]["digest"], after["covered_migrations"]["digest"])
        # No provenance exists: unchanged baseline SQL is not evidence that this
        # edit was executed. The manifest records the new source identity only.

    def test_uncovered_edit_does_not_change_covered_digest(self):
        before = build_manifest(self.groups)
        self.groups["migration"][0][1].write_bytes(b"create table(:another_item)\n")
        after = build_manifest(self.groups)
        self.assertNotEqual(before["digest"], after["digest"])
        self.assertEqual(before["covered_migrations"], after["covered_migrations"])

    def test_every_helper_config_and_dependency_change_invalidates(self):
        for group in ("helper", "construction"):
            for logical, path in self.groups[group]:
                with self.subTest(path=logical):
                    before = build_manifest(self.groups)
                    path.write_bytes(path.read_bytes() + b"\n")
                    self.assertNotEqual(before["digest"], build_manifest(self.groups)["digest"])

    def test_baseline_changes_and_checksum_rejection(self):
        before = build_manifest(self.groups)
        self.groups["baseline-sql"][0][1].write_bytes(b"CREATE TABLE changed (id bigint);\n")
        with self.assertRaisesRegex(ValueError, "baseline SQL hash mismatch"):
            build_manifest(self.groups)
        self.metadata["schema_sha256"] = hashlib.sha256(self.read("baseline-sql")).hexdigest()
        self.write_metadata()
        after = build_manifest(self.groups)
        self.assertNotEqual(before["digest"], after["digest"])
        self.metadata["included_through"] = 20
        self.write_metadata()
        self.assertNotEqual(after["digest"], build_manifest(self.groups)["digest"])

    def test_duplicate_versions_even_with_leading_zero(self):
        self.add("migration", "repo/migrations/010_duplicate.exs", b"create table(:duplicate)\n")
        with self.assertRaisesRegex(ValueError, "duplicate migration version 10"):
            build_manifest(self.groups)

    def test_missing_input_in_every_group(self):
        for group in GROUPS:
            with self.subTest(group=group):
                groups = copy.deepcopy(self.groups)
                logical, _ = groups[group][0]
                groups[group][0] = (logical, self.root / "does-not-exist")
                with self.assertRaisesRegex(ValueError, "missing or unreadable input"):
                    build_manifest(groups)

    def test_empty_groups_and_empty_migration(self):
        for group in GROUPS:
            with self.subTest(group=group):
                groups = dict(self.groups, **{group: []})
                with self.assertRaisesRegex(ValueError, "empty .* inputs"):
                    build_manifest(groups)
        self.groups["migration"][0][1].write_bytes(b" \n")
        with self.assertRaisesRegex(ValueError, "empty migration"):
            build_manifest(self.groups)

    def test_reject_malformed_paths(self):
        for logical in ("/absolute.exs", "../outside.exs", "a/../x.exs", "a//x.exs", "./x.exs", "a\\x.exs", "a/\nx.exs", "", "repo/no_version.exs"):
            with self.subTest(path=logical):
                groups = copy.deepcopy(self.groups)
                groups["migration"][0] = (logical, groups["migration"][0][1])
                with self.assertRaisesRegex(ValueError, "malformed"):
                    build_manifest(groups)

    def test_metadata_cannot_read_undeclared_sql(self):
        for name in ("../outside.sql", "other.sql"):
            with self.subTest(name=name):
                self.metadata["schema_file"] = name
                self.write_metadata()
                with self.assertRaises(ValueError):
                    build_manifest(self.groups)

    def test_cli_param_file_emits_canonical_artifact(self):
        output = self.root / "manifest.json"
        arguments = ["--output", str(output)]
        for group, entries in self.groups.items():
            for logical, physical in entries:
                arguments.extend(["--" + group, logical, str(physical)])
        params = self.root / "args"
        params.write_text("\n".join(arguments), encoding="utf-8")
        main(["@" + str(params)])
        self.assertEqual(output.read_bytes(), canonical_json(build_manifest(self.groups)))


if __name__ == "__main__":
    unittest.main()
