"""Consume the declared artifact through runfiles, never through bazel-out."""

import json
from pathlib import Path
import sys
import unittest

from build.schema_template.manifest import canonical_json, input_digest


ARTIFACT = Path(sys.argv.pop(1))


class ArtifactTest(unittest.TestCase):
    def test_declared_manifest_contract(self):
        raw = ARTIFACT.read_bytes()
        manifest = json.loads(raw)
        self.assertEqual(raw, canonical_json(manifest))
        self.assertEqual(manifest["version"], 1)
        self.assertEqual(manifest["digest"], input_digest(manifest["inputs"]))
        self.assertEqual(manifest["database"], "sr_tpl_" + manifest["digest"][:48])
        versions = manifest["migration_versions"]
        self.assertTrue(versions)
        self.assertEqual(versions, sorted(set(versions)))
        paths = [item["path"] for item in manifest["inputs"]]
        self.assertEqual(paths, sorted(set(paths)))
        for path in (
            "elixir/serviceradar_core/mix.lock",
            "elixir/serviceradar_core/lib/serviceradar/postgres/schema_sql.ex",
            "elixir/serviceradar_core/priv/repo/baseline/metadata.json",
            "elixir/serviceradar_core/priv/repo/baseline/platform_schema.sql",
            "build/schema_template/policy.json",
            "rust/integration-db/registry.sql",
        ):
            self.assertIn(path, paths)


if __name__ == "__main__":
    unittest.main()
