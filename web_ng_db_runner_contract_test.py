"""Contract for the public Bazel query XML describing the guarded DB runner."""

import os
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parent
TARGET = "//elixir/web-ng:networks_live_db_test"
SHARED_FIXTURE_SOURCES = {
    "test/app_domain/dashboards/group_access_db_test.exs",
    "test/app_domain/dashboards/report_jobs_test.exs",
    "test/phoenix/auth/sso_provisioning_test.exs",
    "test/phoenix/controllers/api/admin_authorization_test.exs",
    "test/phoenix/controllers/api/api_endpoint_integration_test.exs",
    "test/phoenix/controllers/api/api_rate_limit_test.exs",
    "test/phoenix/controllers/api/configuration_authentication_db_test.exs",
    "test/phoenix/controllers/api/configuration_lifecycle_db_test.exs",
    "test/phoenix/live/alert_live/show_test.exs",
    "test/phoenix/live/authored_dashboard_live_test.exs",
    "test/phoenix/live/camera_analysis_worker_live_test.exs",
    "test/phoenix/live/device_live_test.exs",
    "test/phoenix/live/device_live/endpoint_inventory_data_db_test.exs",
    "test/phoenix/live/event_live/show_test.exs",
    "test/phoenix/live/log_live/index_test.exs",
    "test/phoenix/live/log_live/netflows_test.exs",
    "test/phoenix/live/log_live/show_test.exs",
    "test/phoenix/live/metric_live/timestamp_rendering_test.exs",
    "test/phoenix/live/security_dashboard_routes_test.exs",
    "test/phoenix/live/settings/ansible_live_test.exs",
    "test/phoenix/live/settings/networks_live_test.exs",
    "test/phoenix/live/settings/snmp_profiles_live/profile_lifecycle_test.exs",
    "test/phoenix/live/settings/notifications_live_test.exs",
    "test/phoenix/live/settings/rbac_live_test.exs",
    "test/phoenix/live/trace_live/show_test.exs",
    "test/phoenix/live/user_live/settings_test.exs",
    "test/serviceradar/identity/timezone_migration_db_test.exs",
    "test/serviceradar/identity/timezone_preference_test.exs",
}

class WebNgDbRunnerContractTest(unittest.TestCase):
    def test_evaluated_runner_attributes(self):
        query = ET.parse(os.environ.get("WEB_DB_TARGET_QUERY", ROOT / "web_ng_db_target_query"))
        rules = query.findall("rule")
        self.assertEqual(len(rules), 1)
        rule = rules[0]
        self.assertEqual(rule.attrib["name"], TARGET)
        attributes = {child.attrib["name"]: child for child in rule if "name" in child.attrib}

        def values(name):
            return [item.attrib["value"] for item in attributes[name]]

        self.assertEqual(
            set(values("srcs")),
            {"//elixir/web-ng:" + source for source in SHARED_FIXTURE_SOURCES},
        )
        env = {
            pair[0].attrib["value"]: pair[1].attrib["value"]
            for pair in attributes["env"]
        }
        self.assertEqual(env["SERVICERADAR_REQUIRE_DB_TESTS"], "1")
        self.assertEqual(env["SERVICERADAR_TEST_DATABASE_OWNERSHIP_TIMEOUT_MS"], "600000")
        self.assertEqual(env["SERVICERADAR_TEST_DB_SHARD"], "serial_0")
        self.assertEqual(env["TEST_CNPG_POOL_SIZE"], "8")
        self.assertTrue({"integration_test", "manual"}.issubset(values("tags")))
        self.assertIn("test/db/networks_live_db_test_helper.exs", values("elixir_opts"))
        self.assertTrue({
            "//build:run_id_file",
            "//config/environments:ci_binpb",
            "//elixir/serviceradar_core:test/db/integration_env.exs",
            "//elixir/serviceradar_core:test/db/integration_env_config.exs",
            "//elixir/serviceradar_core:test/db/fixture_config.exs",
            "//elixir/serviceradar_core:config/test_database_guard.exs",
        }.issubset(values("data")))
        self.assertTrue(any(value.endswith("//:incompatible") for value in values("target_compatible_with")))


if __name__ == "__main__":
    unittest.main()
