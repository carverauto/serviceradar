"""Source-level contracts for the analytics CNPG image.

These tests read BUILD sources, not bazel-out. They exist so a later edit
cannot put pg_duckdb on the Timescale primary or Timescale on the analytics
head without failing before an image is published.
"""

from __future__ import annotations

from pathlib import Path
import unittest


class AnalyticsImageContractTest(unittest.TestCase):
    def setUp(self) -> None:
        here = Path(__file__).resolve().parent
        self.cnpg = (here / "cnpg_image.bzl").read_text()
        self.analytics = (here / "analytics_image.bzl").read_text()

    def test_primary_image_does_not_layer_pg_duckdb(self) -> None:
        # The primary Cluster loads TimescaleDB in shared_preload_libraries.
        # pg_duckdb calling standard_planner() next to that is a SIGSEGV
        # (duckdb/pg_duckdb#845, #963).
        start = self.cnpg.index('name = "cnpg_image_amd64"')
        chunk = self.cnpg[start : start + 800]
        self.assertIn("timescaledb_extension_layer", chunk)
        self.assertNotIn("pg_duckdb", chunk)
        self.assertNotIn("pgduckdb", chunk)

    def test_analytics_image_uses_cnpg_base_and_pg_duckdb_layer(self) -> None:
        start = self.analytics.index('name = "cnpg_analytics_image_amd64"')
        chunk = self.analytics[start : start + 1200]
        self.assertIn("cloudnativepg_postgresql_18_linux_amd64", chunk)
        self.assertIn("pg_duckdb_extension_layer", chunk)
        self.assertIn("cnpg_analytics_runtime_layer", chunk)
        self.assertNotIn("timescaledb_extension_layer", chunk)
        self.assertNotIn("age_extension_layer", chunk)
        self.assertNotIn("postgis_extension_layer", chunk)

    def test_analytics_image_is_not_a_thin_pgduckdb_republish(self) -> None:
        start = self.analytics.index('name = "cnpg_analytics_image_amd64"')
        chunk = self.analytics[start : start + 1200]
        self.assertNotIn("pgduckdb_18_linux_amd64", chunk)

    def test_boot_smoke_fixture_has_an_explicit_failure_path(self) -> None:
        smoke = (Path(__file__).resolve().parent / "cnpg_analytics_boot_smoke.py").read_text()
        self.assertIn("FAILED: synthetic timeseries aggregate", smoke)
        self.assertIn("3:20.0", smoke)
        self.assertIn("synthetic-timeseries.parquet", smoke)
        self.assertNotIn("wait for log", smoke.lower())


if __name__ == "__main__":
    unittest.main()
