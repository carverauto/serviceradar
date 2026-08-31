"""Static contract for the guarded web-ng database-backed test runner."""

import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parent
WEB_BUILD = ROOT / "elixir/web-ng/BUILD.bazel"
WEB_TEST_CONFIG = ROOT / "elixir/web-ng/config/test.exs"
WORKFLOW = ROOT / "buildbuddy.yaml"
TARGET = "//elixir/web-ng:networks_live_db_test"


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

        self.assertEqual(build.count('name = "networks_live_db_test"'), 1)
        self.assertIn(
            'srcs = ["test/phoenix/live/settings/networks_live_test.exs"]', rule
        )
        self.assertIn('"SERVICERADAR_REQUIRE_DB_TESTS": "1"', rule)
        self.assertIn('"SERVICERADAR_TEST_DB_SHARD": "serial_0"', rule)
        self.assertIn('"TEST_CNPG_POOL_SIZE": "2"', rule)
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

    def test_web_test_config_consumes_the_guarded_url_without_downgrading_tls(self):
        config = WEB_TEST_CONFIG.read_text(encoding="utf-8")

        self.assertIn('System.get_env("SERVICERADAR_TEST_DATABASE_URL")', config)
        self.assertIn('System.get_env("SERVICERADAR_TEST_DATABASE_CA_CERT")', config)
        self.assertIn(
            'System.get_env("SERVICERADAR_TEST_DATABASE_SERVER_NAME")', config
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
