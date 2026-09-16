#!/usr/bin/env python3
"""Pin opt-in StarRocks analytics chart values and lab cluster versions."""

from pathlib import Path
import os
import unittest


def _repo_root() -> Path:
    srcdir = os.environ.get("TEST_SRCDIR")
    workspace = os.environ.get("TEST_WORKSPACE")
    if srcdir and workspace:
        candidate = Path(srcdir) / workspace
        if candidate.is_dir():
            return candidate
    return Path(__file__).resolve().parent.parent.parent


REPO_ROOT = _repo_root()
VALUES = (REPO_ROOT / "helm" / "serviceradar" / "values.yaml").read_text()
TEMPLATE = (
    REPO_ROOT / "helm" / "serviceradar" / "templates" / "starrocks-analytics-config.yaml"
).read_text()
LAB_CLUSTER = (REPO_ROOT / "k8s" / "starrocks" / "values-cluster.yaml").read_text()
LAB_README = (REPO_ROOT / "k8s" / "starrocks" / "README.md").read_text()
SCHEMA_DIR = (
    REPO_ROOT / "elixir" / "serviceradar_core" / "priv" / "starrocks"
)


class StarRocksAnalyticsPinsTest(unittest.TestCase):
    def test_chart_is_opt_in_and_pinned(self):
        self.assertIn('operatorChartVersion: "1.11.7"', VALUES)
        self.assertIn('imageTag: "3.5.21"', VALUES)
        self.assertIn("enabled: false", VALUES)
        self.assertIn("shadowDatasets: []", VALUES)
        self.assertIn("cutoverDatasets: []", VALUES)
        self.assertIn("analytics.starrocks.enabled", TEMPLATE)
        self.assertNotIn("namespace: serviceradar", TEMPLATE)
        self.assertNotIn("namespace: demo", TEMPLATE)

    def test_lab_cluster_pins_shared_nothing_3_5_21(self):
        self.assertIn('tag: "3.5.21"', LAB_CLUSTER)
        self.assertIn("enabledCn: false", LAB_CLUSTER)
        self.assertIn("storageClassName: local-path", LAB_CLUSTER)
        self.assertIn("replicas: 3", LAB_CLUSTER)
        self.assertNotIn("objectStorageBucket", LAB_CLUSTER)
        self.assertNotIn("namespace: demo", LAB_CLUSTER)
        self.assertNotIn("namespace: serviceradar", LAB_CLUSTER)
        self.assertIn("namespace starrocks", LAB_README)
        self.assertIn("Do not copy lab node procedures", LAB_README)
        self.assertIn("Hosted shared-data (CN + object storage) is not this", LAB_README)

    def test_lab_shared_nothing_cannot_prove_hosted_restore_drills(self):
        """3.4 CN-cache / object-outage / full restore are hosted shared-data drills."""
        self.assertIn("enabledCn: false", LAB_CLUSTER)
        self.assertIn("enabledBe: true", LAB_CLUSTER)
        self.assertNotRegex(LAB_CLUSTER, r"aws_s3|s3_endpoint|object_storage")
        self.assertIn("profile: sharedNothing", VALUES)
        self.assertIn('objectStorageBucket: ""', VALUES)
        self.assertIn("cutoverDatasets: []", VALUES)

    def test_schema_covers_flows_metrics_logs_events_and_hourly_mvs(self):
        names = sorted(path.name for path in SCHEMA_DIR.glob("*.sql"))
        self.assertIn("0001_ocsf_network_activity.sql", names)
        self.assertIn("0002_timeseries_metrics.sql", names)
        self.assertIn("0003_logs.sql", names)
        self.assertIn("0004_events.sql", names)
        self.assertIn("0005_hourly_materialized_views.sql", names)
        self.assertIn("0006_ocsf_network_activity_sampler.sql", names)
        self.assertIn("0007_events_reader_columns.sql", names)
        self.assertIn("0008_ocsf_network_activity_attribution.sql", names)
        flows = (SCHEMA_DIR / "0001_ocsf_network_activity.sql").read_text()
        self.assertIn("sampler_address VARCHAR(64)", flows)
        self.assertIn("pid INT", flows)
        self.assertIn("comm VARCHAR(256)", flows)
        self.assertIn("cmdline VARCHAR(65533)", flows)
        self.assertIn("workload_identity VARCHAR(65533)", flows)
        attr = (SCHEMA_DIR / "0008_ocsf_network_activity_attribution.sql").read_text()
        self.assertIn("ADD COLUMN IF NOT EXISTS pid", attr)
        self.assertIn("ADD COLUMN IF NOT EXISTS comm", attr)
        self.assertIn("ADD COLUMN IF NOT EXISTS cmdline", attr)
        self.assertIn("ADD COLUMN IF NOT EXISTS workload_identity", attr)
        metrics = (SCHEMA_DIR / "0002_timeseries_metrics.sql").read_text()
        self.assertIn("CREATE TABLE IF NOT EXISTS serviceradar.timeseries_metrics", metrics)
        self.assertNotIn("demo", metrics)
        events = (SCHEMA_DIR / "0004_events.sql").read_text()
        self.assertIn("Current alert state remains in CNPG", events)
        self.assertIn("src_endpoint_ip VARCHAR(64)", events)
        self.assertIn("firewall_rule_name VARCHAR(256)", events)
        self.assertIn("source_type VARCHAR(64)", events)
        alter = (SCHEMA_DIR / "0007_events_reader_columns.sql").read_text()
        self.assertIn("ADD COLUMN IF NOT EXISTS src_endpoint_ip", alter)
        mvs = (SCHEMA_DIR / "0005_hourly_materialized_views.sql").read_text()
        self.assertIn(
            "CREATE MATERIALIZED VIEW IF NOT EXISTS serviceradar.ocsf_network_activity_hourly",
            mvs,
        )
        self.assertIn(
            "CREATE MATERIALIZED VIEW IF NOT EXISTS serviceradar.timeseries_metrics_hourly",
            mvs,
        )
        self.assertIn(
            "CREATE MATERIALIZED VIEW IF NOT EXISTS serviceradar.events_hourly",
            mvs,
        )
        self.assertIn("REFRESH ASYNC", mvs)


if __name__ == "__main__":
    unittest.main()
