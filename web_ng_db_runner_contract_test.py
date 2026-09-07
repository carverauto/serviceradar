"""Static contract for the guarded web-ng database-backed test runner."""

import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parent
WEB_BUILD = ROOT / "elixir/web-ng/BUILD.bazel"
WEB_TEST_CONFIG = ROOT / "elixir/web-ng/config/test.exs"
WORKFLOW = ROOT / "buildbuddy.yaml"
TARGET = "//elixir/web-ng:networks_live_db_test"
SHARED_FIXTURE_SOURCES = {
    "test/app_domain/dashboards/group_access_db_test.exs",
    "test/app_domain/dashboards/report_jobs_test.exs",
    "test/phoenix/auth/sso_provisioning_test.exs",
    "test/phoenix/controllers/api/admin_authorization_test.exs",
    "test/phoenix/controllers/api/api_endpoint_integration_test.exs",
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


def named_rule(source: str, kind: str, name: str) -> str:
    lines = source.splitlines(keepends=True)
    for index, line in enumerate(lines):
        if line == f"{kind}(\n" and f'name = "{name}"' in "".join(
            lines[index : index + 5]
        ):
            depth = 0
            rule = []
            for candidate in lines[index:]:
                depth += candidate.count("(") - candidate.count(")")
                rule.append(candidate)
                if depth == 0:
                    return "".join(rule)
    raise AssertionError(f"{kind} {name} is missing")


def named_action(source: str, name: str) -> str:
    match = re.search(
        rf'^  - name: "{re.escape(name)}"\n(?P<body>.*?)(?=^  - name:|\Z)',
        source,
        re.MULTILINE | re.DOTALL,
    )
    if not match:
        raise AssertionError(f"workflow action {name} is missing")
    return match.group(0)


class WebNgDbRunnerContractTest(unittest.TestCase):
    def test_networks_live_has_one_guarded_manual_db_target(self):
        build = WEB_BUILD.read_text(encoding="utf-8")
        rule = named_rule(build, "ex_unit_test", "networks_live_db_test")
        srcs_match = re.search(
            r"^    srcs = \[\n(?P<body>.*?)^    \],\n",
            rule,
            re.MULTILINE | re.DOTALL,
        )

        self.assertEqual(build.count('name = "networks_live_db_test"'), 1)
        self.assertIsNotNone(srcs_match)
        self.assertEqual(
            set(re.findall(r'^        "([^"]+)",$', srcs_match.group("body"), re.MULTILINE)),
            SHARED_FIXTURE_SOURCES,
        )
        self.assertIn('"test/db/networks_live_db_test_helper.exs"', rule)
        self.assertIn('"SERVICERADAR_REQUIRE_DB_TESTS": "1"', rule)
        self.assertIn(
            '"SERVICERADAR_TEST_DATABASE_OWNERSHIP_TIMEOUT_MS": "600000"', rule
        )
        self.assertIn('"SERVICERADAR_TEST_DB_SHARD": "serial_0"', rule)
        self.assertIn('"TEST_CNPG_POOL_SIZE": "8"', rule)
        self.assertIn('"integration_test"', rule)
        self.assertIn('"manual"', rule)
        self.assertIn('target_compatible_with = requires_shared_fixture()', rule)
        self.assertIn('"//build:run_id_file"', rule)
        self.assertIn('"//config/environments:ci_binpb"', rule)
        self.assertIn(
            '"//elixir/serviceradar_core:test/db/integration_env.exs"', rule
        )
        self.assertIn(
            '"//elixir/serviceradar_core:test/db/integration_env_config.exs"',
            rule,
        )
        self.assertIn(
            '"//elixir/serviceradar_core:test/db/fixture_config.exs"', rule
        )
        self.assertIn(
            '"//elixir/serviceradar_core:config/test_database_guard.exs"', rule
        )

    def test_web_test_config_consumes_the_guarded_url_without_downgrading_tls(self):
        config = WEB_TEST_CONFIG.read_text(encoding="utf-8")

        url_getter = 'System.get_env("SERVICERADAR_TEST_DATABASE_URL")'
        ca_getter = 'System.get_env("SERVICERADAR_TEST_DATABASE_CA_CERT")'
        guard_call = (
            "ServiceRadar.DB.TestDatabaseGuard.validate!(guarded_database_url"
        )
        repo_url = "[url: guarded_database_url]"

        self.assertIn(url_getter, config)
        self.assertIn(ca_getter, config)
        self.assertIn(
            'System.get_env("SERVICERADAR_TEST_DATABASE_SERVER_NAME")', config
        )
        self.assertIn(
            "guarded web-ng database tests require "
            "SERVICERADAR_TEST_DATABASE_CA_CERT",
            config,
        )
        self.assertIn(
            "guarded web-ng database tests require "
            "SERVICERADAR_TEST_DATABASE_SERVER_NAME",
            config,
        )
        self.assertIn(guard_call, config)
        self.assertIn('ssl_mode: "verify-full"', config)
        self.assertIn("ca_configured?: guarded_ca_certs != []", config)
        self.assertIn(repo_url, config)
        self.assertLess(config.index(guard_call), config.index(repo_url))
        self.assertIn(
            "cnpg_verify_peer = guarded_database? or "
            "cnpg_ssl_mode in ~w(verify-ca verify-full)",
            config,
        )
        self.assertIn("Keyword.put(opts, :cacerts, guarded_ca_certs)", config)
        self.assertIn(
            'if (guarded_database? or cnpg_ssl_mode == "verify-full") and\n'
            '         cnpg_tls_server_name != "" do',
            config,
        )
        self.assertNotIn(
            'if cnpg_verify_peer and cnpg_tls_server_name != "" do', config
        )
        self.assertIn("server_name_indication", config)
        self.assertIn("customize_hostname_check", config)

    def test_bazelci_runs_web_db_target_after_core_lanes_and_before_teardown(self):
        action = named_action(WORKFLOW.read_text(encoding="utf-8"), "BazelCI")
        ordinary = (
            "bazel test $FLAGS --build_tests_only "
            "--build_tag_filters=integration_test,-large_ingestion_test,-acceptance_test "
            "--test_tag_filters=integration_test,-large_ingestion_test,-acceptance_test //..."
        )
        web = f"bazel test $FLAGS {TARGET}"
        teardown = "bazel test $FLAGS //rust/integration-db:teardown_db"

        self.assertEqual(action.count(web), 1)
        self.assertLess(action.index(ordinary), action.index(web))
        self.assertIn(teardown, action)
        self.assertLess(action.index("trap cleanup EXIT"), action.index(web))


if __name__ == "__main__":
    unittest.main()
