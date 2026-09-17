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
VALUES_DEMO = (REPO_ROOT / "helm" / "serviceradar" / "values-demo.yaml").read_text()
TEMPLATE = (
    REPO_ROOT / "helm" / "serviceradar" / "templates" / "starrocks-analytics-config.yaml"
).read_text()
HELPERS = (
    REPO_ROOT / "helm" / "serviceradar" / "templates" / "_helpers.tpl"
).read_text()
CORE_TMPL = (REPO_ROOT / "helm" / "serviceradar" / "templates" / "core.yaml").read_text()
WEB_TMPL = (REPO_ROOT / "helm" / "serviceradar" / "templates" / "web.yaml").read_text()
LAB_CLUSTER = (REPO_ROOT / "k8s" / "starrocks" / "values-cluster.yaml").read_text()
LAB_SHARED_DATA = (
    REPO_ROOT / "k8s" / "starrocks" / "values-cluster-shared-data.yaml"
).read_text()
LAB_README = (REPO_ROOT / "k8s" / "starrocks" / "README.md").read_text()
STORAGE_VOLUME_JOB = (
    REPO_ROOT / "helm" / "serviceradar" / "templates" / "starrocks-storage-volume-job.yaml"
).read_text()
CATALOG_JOB = (
    REPO_ROOT / "helm" / "serviceradar" / "templates" / "starrocks-catalog-job.yaml"
).read_text()
CATALOG_NETPOL = (
    REPO_ROOT
    / "helm"
    / "serviceradar"
    / "templates"
    / "starrocks-catalog-network-policy.yaml"
).read_text()
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
        self.assertIn("catalog:", VALUES)
        self.assertIn("enabled: false", VALUES)
        self.assertIn("name: cnpg_platform", VALUES)
        self.assertIn('driverUrl: "file:///opt/starrocks/jdbc/postgresql.jar"', VALUES)
        self.assertNotIn("repo1.maven.org", VALUES)
        self.assertNotIn("repo1.maven.org", TEMPLATE)
        pin = (REPO_ROOT / "third_party" / "jdbc" / "postgresql.pin").read_text()
        self.assertIn("runtime_path=file:///opt/starrocks/jdbc/postgresql.jar", pin)
        self.assertIn("version=42.7.13", pin)
        self.assertRegex(pin, r"sha256=[0-9a-f]{64}")
        self.assertNotIn("42.7.4", pin)
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
        self.assertIn("values-cluster-shared-data.yaml", LAB_README)
        self.assertIn("stays on the shared-nothing file", LAB_README)

    def test_lab_shared_nothing_cannot_prove_hosted_restore_drills(self):
        """3.4 CN-cache / object-outage / full restore are hosted shared-data drills."""
        self.assertIn("enabledCn: false", LAB_CLUSTER)
        self.assertIn("enabledBe: true", LAB_CLUSTER)
        self.assertNotRegex(LAB_CLUSTER, r"aws_s3|s3_endpoint|object_storage")
        self.assertIn("profile: sharedNothing", VALUES)
        self.assertIn('objectStorageBucket: ""', VALUES)
        self.assertIn("cutoverDatasets: []", VALUES)

    def test_carverauto_shared_data_overlay_uses_cn_and_not_barman(self):
        self.assertIn("enabledBe: false", LAB_SHARED_DATA)
        self.assertIn("enabledCn: true", LAB_SHARED_DATA)
        self.assertIn("run_mode = shared_data", LAB_SHARED_DATA)
        self.assertIn("enable_load_volume_from_conf = false", LAB_SHARED_DATA)
        self.assertIn("starrocks/cn-ubuntu", LAB_SHARED_DATA)
        self.assertNotIn("aws_s3_access_key", LAB_SHARED_DATA)
        self.assertNotIn("cnpg-backup-s3-creds", LAB_SHARED_DATA)
        self.assertIn("serviceradar-demo-analytics", LAB_SHARED_DATA)
        self.assertIn("secretName: serviceradar-analytics-object-store", VALUES_DEMO)
        self.assertIn("objectStorageBucket: serviceradar-demo-analytics", VALUES_DEMO)
        self.assertIn("profile: sharedData", VALUES_DEMO)
        self.assertIn("starrocks-storage-volume", STORAGE_VOLUME_JOB)
        self.assertIn("secretKeyRef", STORAGE_VOLUME_JOB)
        self.assertIn("access_key_id", STORAGE_VOLUME_JOB)
        self.assertNotIn("cnpg-backup-s3-creds", STORAGE_VOLUME_JOB)
        self.assertLess(
            STORAGE_VOLUME_JOB.find("profile is sharedData"),
            STORAGE_VOLUME_JOB.find("kind: Job"),
        )

    def test_catalog_job_is_gated_off_and_uses_an_infra_secret(self):
        self.assertIn("catalog.enabled", CATALOG_JOB)
        self.assertIn("kind: Job", CATALOG_JOB)
        self.assertLess(CATALOG_JOB.find("catalog.enabled"), CATALOG_JOB.find("kind: Job"))
        self.assertIn("secretName is required when catalog.enabled is true", CATALOG_JOB)
        self.assertIn("createSql", CATALOG_JOB)
        self.assertNotIn("repo1.maven.org", CATALOG_JOB)
        self.assertIn("automountServiceAccountToken: false", CATALOG_JOB)
        self.assertIn("kind: NetworkPolicy", CATALOG_NETPOL)
        self.assertLess(
            CATALOG_NETPOL.find("catalog.enabled"),
            CATALOG_NETPOL.find("kind: NetworkPolicy"),
        )
        self.assertIn("sourceNamespace", CATALOG_NETPOL)
        self.assertIn("port: 5432", CATALOG_NETPOL)
        self.assertIn("starrocks-catalog-cnpg", CATALOG_NETPOL)
        self.assertIn('secretName: ""', VALUES)
        self.assertIn("sourceNamespace: starrocks", VALUES)
        self.assertIn("    catalog:\n      enabled: false\n", VALUES)
        self.assertIn("mountPath: /opt/starrocks/jdbc", LAB_CLUSTER)
        self.assertIn("name: jdbc", LAB_CLUSTER)
        self.assertIn("emptyDirs:", LAB_CLUSTER)
        self.assertIn("volumeMounts:", LAB_CLUSTER)
        self.assertIn("alpine:3.21.3", LAB_CLUSTER)
        self.assertIn("wget -T 30", LAB_CLUSTER)
        self.assertNotIn("storageSize: 1Gi", LAB_CLUSTER)
        self.assertIn(
            "6e0e4cc2d8cae902084f8a2b18728b073a6fd9d1f87c9d8bff8f298c18185b93",
            LAB_CLUSTER,
        )

    def test_starrocks_env_is_injected_when_analytics_is_enabled(self):
        self.assertIn("serviceradar.starrocksAnalyticsEnv", HELPERS)
        self.assertIn("SERVICERADAR_STARROCKS_CATALOG_ENABLED", HELPERS)
        self.assertIn("SERVICERADAR_STARROCKS_CUTOVER_DATASETS", HELPERS)
        self.assertLess(
            HELPERS.find("if $sr.enabled"),
            HELPERS.find("SERVICERADAR_STARROCKS_CATALOG_ENABLED"),
        )
        self.assertIn("serviceradar.starrocksAnalyticsEnv", CORE_TMPL)
        self.assertIn("serviceradar.starrocksAnalyticsEnv", WEB_TMPL)
        self.assertIn("requireStarRocksForNetFlow", HELPERS)
        self.assertIn("starrocksShadowDatasets", HELPERS)
        self.assertIn('list "flows" "metrics" "logs" "events"', HELPERS)
        self.assertIn("SERVICERADAR_STARROCKS_ENABLED", HELPERS)
        self.assertIn("SERVICERADAR_STARROCKS_FE_HOST", HELPERS)
        self.assertIn("SERVICERADAR_STARROCKS_FE_QUERY_PORT", HELPERS)
        self.assertIn("SERVICERADAR_STARROCKS_FE_HTTP", HELPERS)
        self.assertIn("flowCollector.enabled requires analytics.starrocks.enabled", HELPERS)
        flow_collector = (
            REPO_ROOT / "helm" / "serviceradar" / "templates" / "flow-collector.yaml"
        ).read_text()
        self.assertIn("requireStarRocksForNetFlow", flow_collector)
        self.assertLess(
            flow_collector.find("flowCollector.enabled"),
            flow_collector.find("requireStarRocksForNetFlow"),
        )
        self.assertIn("`partition` VARCHAR(128)", (SCHEMA_DIR / "0002_timeseries_metrics.sql").read_text())

    def test_compose_keeps_collector_off_and_profiles_starrocks(self):
        compose = (REPO_ROOT / "docker-compose.yml").read_text()
        self.assertIn("container_name: serviceradar-starrocks", compose)
        self.assertIn("starrocks/allin1-ubuntu:3.5.21", compose)
        self.assertIn("SERVICERADAR_STARROCKS_ENABLED=${STARROCKS_ENABLED:-false}", compose)
        self.assertIn("--profile starrocks", compose)
        self.assertIn("--profile flows", compose)
        flow_idx = compose.find("  flow-collector:")
        star_idx = compose.find("  starrocks:")
        self.assertGreater(flow_idx, 0)
        self.assertGreater(star_idx, 0)
        flow_block = compose[flow_idx : flow_idx + 1600]
        self.assertIn("- flows", flow_block)
        self.assertIn("- network-ingest", flow_block)
        self.assertNotIn("- starrocks", flow_block)
        self.assertIn("starrocks:", flow_block)
        star_block = compose[star_idx : star_idx + 700]
        self.assertIn("- starrocks", star_block)
        self.assertIn("- flows", star_block)

    def test_demo_overlay_enables_catalog_not_cutover(self):
        self.assertIn("enabled: true", VALUES_DEMO)
        self.assertIn("secretName: serviceradar-starrocks-catalog", VALUES_DEMO)
        self.assertIn("cutoverDatasets: []", VALUES_DEMO)
        self.assertIn("shadowDatasets: []", VALUES_DEMO)
        self.assertIn("sslmode=require", VALUES_DEMO)
        self.assertNotIn("repo1.maven.org", VALUES_DEMO)
        self.assertIn("sourceNamespace: starrocks", VALUES_DEMO)

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
        self.assertIn("0009_cnpg_platform_catalog.sql", names)
        flows = (SCHEMA_DIR / "0001_ocsf_network_activity.sql").read_text()
        self.assertIn("sampler_address VARCHAR(64)", flows)
        self.assertIn("pid INT", flows)
        self.assertIn("comm VARCHAR(256)", flows)
        self.assertIn("cmdline VARCHAR(65533)", flows)
        self.assertIn("workload_identity VARCHAR(65533)", flows)
        attr = (SCHEMA_DIR / "0008_ocsf_network_activity_attribution.sql").read_text()
        self.assertIn("ADD COLUMN pid", attr)
        self.assertIn("ADD COLUMN comm", attr)
        self.assertIn("ADD COLUMN cmdline", attr)
        self.assertIn("ADD COLUMN workload_identity", attr)
        self.assertNotIn("IF NOT EXISTS", attr)
        metrics = (SCHEMA_DIR / "0002_timeseries_metrics.sql").read_text()
        self.assertIn("CREATE TABLE IF NOT EXISTS serviceradar.timeseries_metrics", metrics)
        self.assertNotIn("demo", metrics)
        events = (SCHEMA_DIR / "0004_events.sql").read_text()
        self.assertIn("Current alert state remains in CNPG", events)
        self.assertIn("src_endpoint_ip VARCHAR(64)", events)
        self.assertIn("firewall_rule_name VARCHAR(256)", events)
        self.assertIn("source_type VARCHAR(64)", events)
        alter = (SCHEMA_DIR / "0007_events_reader_columns.sql").read_text()
        self.assertIn("ADD COLUMN src_endpoint_ip", alter)
        self.assertNotIn("IF NOT EXISTS", alter)
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
