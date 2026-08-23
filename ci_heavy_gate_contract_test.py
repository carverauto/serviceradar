"""Static contract for the explicit-only core integration benchmark harness."""

import hashlib
import re
import sys
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parent
WORKFLOW = ROOT / "buildbuddy.yaml"
OBSERVER_SOURCE = ROOT / "rust/integration-db/src/connection_observer.rs"
OBSERVER_BINARY = ROOT / "rust/integration-db/src/bin/observe_connections.rs"
OBSERVER_BUILD = ROOT / "rust/integration-db/BUILD.bazel"
CORE_BUILD = ROOT / "elixir/serviceradar_core/BUILD.bazel"
INTEGRATION_SHARDS = ROOT / "build/integration_shards.bzl"
TEST_HELPER = ROOT / "elixir/serviceradar_core/test/test_helper.exs"
ORDINARY_RESULTS_ROUTER = (
    ROOT
    / "elixir/serviceradar_core/test/serviceradar/results_router_integration_test.exs"
)
RELEASE_RESULTS_ROUTER = (
    ROOT
    / "elixir/serviceradar_core/test/release_gates/large_ingestion/results_router_release_gate_test.exs"
)
RELEASE_IDENTIFIER_CARDINALITY = (
    ROOT
    / "elixir/serviceradar_core/test/release_gates/large_ingestion/identifier_cardinality_release_gate_test.exs"
)
FIXED_EXTERNAL_RESOURCE_PATHS = (
    "test/integration/netflow_ingestion_integration_test.exs",
    "test/integration/proxmox_api_smoke_integration_test.exs",
    "test/serviceradar/scans/adhoc_scan_nats_e2e_test.exs",
)


def fixed_external_resource_sources() -> tuple[str, ...]:
    source = INTEGRATION_SHARDS.read_text(encoding="utf-8")
    match = re.search(
        r"_FIXED_EXTERNAL_RESOURCE_SRCS = \[\n(?P<sources>.*?)\n\]",
        source,
        re.DOTALL,
    )
    if not match:
        raise AssertionError("_FIXED_EXTERNAL_RESOURCE_SRCS is missing")
    return tuple(re.findall(r'^    "([^"]+)",$', match.group("sources"), re.MULTILINE))


def integration_only_branch() -> str:
    source = TEST_HELPER.read_text(encoding="utf-8")
    selection = 'if System.get_env("SERVICERADAR_ONLY_INTEGRATION") in ["1", "true", "TRUE"] do'
    start = source.index(selection)
    end = source.index("  else\n    ExUnit.start(", start)
    return source[start:end]


def integration_benchmark_action() -> str:
    workflow = WORKFLOW.read_text(encoding="utf-8")
    match = re.search(
        r'^  - name: "IntegrationBenchmark"\n(?P<block>.*?)(?=^  - name:|\Z)',
        workflow,
        re.MULTILINE | re.DOTALL,
    )
    if not match:
        raise AssertionError("IntegrationBenchmark action is missing")
    return match.group(0)


def observe_connections_rule() -> str:
    lines = OBSERVER_BUILD.read_text(encoding="utf-8").splitlines(keepends=True)
    for index, line in enumerate(lines):
        if line == "rust_binary(\n" and 'name = "observe_connections"' in "".join(lines[index : index + 4]):
            depth = 0
            rule = []
            for candidate in lines[index:]:
                depth += candidate.count("(") - candidate.count(")")
                rule.append(candidate)
                if depth == 0:
                    return "".join(rule)
    raise AssertionError("observe_connections rust_binary rule is missing")


def named_starlark_rule(source: str, rule_kind: str, name: str) -> str:
    lines = source.splitlines(keepends=True)
    for index, line in enumerate(lines):
        if line == f"{rule_kind}(\n" and f'name = "{name}"' in "".join(
            lines[index : index + 5]
        ):
            depth = 0
            rule = []
            for candidate in lines[index:]:
                depth += candidate.count("(") - candidate.count(")")
                rule.append(candidate)
                if depth == 0:
                    return "".join(rule)
    raise AssertionError(f"{rule_kind} {name} is missing")


def normalized(value: str) -> bytes:
    return ("\n".join(line.rstrip() for line in value.splitlines()) + "\n").encode()


def harness_hash() -> str:
    digest = hashlib.sha256()
    for value in (
        integration_benchmark_action(),
        OBSERVER_SOURCE.read_text(encoding="utf-8"),
        OBSERVER_BINARY.read_text(encoding="utf-8"),
        observe_connections_rule(),
    ):
        digest.update(normalized(value))
    return digest.hexdigest()


class IntegrationBenchmarkContractTest(unittest.TestCase):
    def setUp(self):
        self.action = integration_benchmark_action()

    def test_action_is_explicit_only_and_uses_the_existing_runner(self):
        self.assertIn('pool: "workflows"', self.action)
        self.assertIn(
            "container_image: \"docker://registry.carverauto.dev/serviceradar/buildbuddy-workflow-runner:v1.0.24.3\"",
            self.action,
        )
        self.assertIn('branches:\n          - "benchmark/parallel-core-integration"', self.action)
        self.assertNotIn("pull_request:", self.action)
        self.assertNotIn("merge", self.action.lower())

    def test_lifecycle_has_the_fixed_measurement_contract(self):
        for required in (
            "SERVICERADAR_BENCHMARK_EXPECTED_SHA",
            "git rev-parse HEAD",
            "BAZEL_PROFILE=ci",
            "--flaky_test_attempts=1",
            "--test_output=all",
            "SERVICERADAR_TEST_SLOWEST=15",
            "--strategy=TestRunner=local",
            "integration_test,-large_ingestion_test,-acceptance_test",
            "//rust/integration-db:observe_connections",
            "--max-seconds 1800",
            "od -An -tx1 -N4 /dev/urandom",
            "//:buildbuddy_setup_fixture_env",
            "//rust/integration-db:teardown_db",
        ):
            self.assertIn(required, self.action)

    def test_expected_sha_is_checked_before_any_build_or_registry_work(self):
        sha_check = self.action.index("SERVICERADAR_BENCHMARK_EXPECTED_SHA")
        docker_auth = self.action.index("//:buildbuddy_setup_docker_auth")
        full_build = self.action.index("bazel build -c opt --config=ci")
        self.assertLess(sha_check, docker_auth)
        self.assertLess(sha_check, full_build)

    def test_preflight_is_private_and_cannot_warm_the_measured_run(self):
        for required in (
            "PREFLIGHT_RUN_ID=",
            "PREFLIGHT_ENV_FILE=",
            "trap 'rm -f \"$PREFLIGHT_ENV_FILE\"' EXIT",
            "--//build:run_id=$PREFLIGHT_RUN_ID",
            "--//build:run_id=$RUN_ID",
        ):
            self.assertIn(required, self.action)

        preflight_start = self.action.index("PREFLIGHT_RUN_ID=")
        measured_start = self.action.index("\n          RUN_ID=", preflight_start)
        self.assertLess(preflight_start, measured_start)
        self.assertIn("(\n", self.action[preflight_start - 80 : preflight_start])
        self.assertLess(
            self.action.index("trap 'rm -f \"$PREFLIGHT_ENV_FILE\"' EXIT"),
            measured_start,
        )

    def test_preflight_maps_its_private_file_to_the_fixture_helper(self):
        preflight_start = self.action.index("PREFLIGHT_RUN_ID=")
        helper = self.action.index("//:buildbuddy_setup_fixture_env", preflight_start)
        mapping = self.action.index(
            'SERVICERADAR_FIXTURE_ENV_FILE="$PREFLIGHT_ENV_FILE"', preflight_start
        )
        self.assertLess(mapping, helper)
        self.assertIn("export SERVICERADAR_FIXTURE_ENV_FILE", self.action[mapping:helper])

    def test_measured_flags_are_defined_before_each_measured_lifecycle_use(self):
        measured_start = self.action.index("\n          RUN_ID=")
        measured = self.action[measured_start:]
        flags = measured.index('FLAGS="-c opt --config=ci')
        self.assertNotIn("PREFLIGHT_FLAGS", measured)
        for use in (
            "bazel test $FLAGS //rust/integration-db:teardown_db",
            "bazel test $FLAGS //rust/integration-db:sweep_stale_dbs",
            "bazel test $FLAGS //rust/integration-db:provision_db",
            "bazel test $FLAGS //... --test_tag_filters=integration_test,-large_ingestion_test,-acceptance_test",
        ):
            self.assertIn(use, measured)
            self.assertLess(flags, measured.index(use))

    def test_clock_and_observer_markers_cannot_drift(self):
        self.assertIn("mktemp -d", self.action)
        for marker in ("READY_FILE", "SUITE_COMPLETE_FILE", "QUIESCENT_FILE", "STOP_FILE"):
            self.assertRegex(self.action, rf'{marker}="\$OBSERVER_DIR/')
            self.assertIn(f'[ ! -e "${{{marker}}}" ]', self.action)

        self.assertLess(self.action.index("migrate_template"), self.action.index("START_NS"))
        measured_check = self.action.index("template=\"$(bazel run", self.action.index("START_NS"))
        self.assertGreater(measured_check, self.action.index("START_NS"))
        self.assertNotIn("migrate_template", self.action[measured_check:])

        teardown = self.action.index("//rust/integration-db:teardown_db")
        end = self.action.index("END_NS=", teardown)
        stop = self.action.index("touch \"$STOP_FILE\"", end)
        observer_wait = self.action.index("wait \"$OBSERVER_PID\"", stop)
        self.assertLess(teardown, end)
        self.assertLess(end, stop)
        self.assertLess(stop, observer_wait)

    def test_cleanup_quiesces_before_teardown_and_preserves_status_priority(self):
        cleanup = self.action[self.action.index("cleanup() {") :]
        suite_complete = cleanup.index("touch \"$SUITE_COMPLETE_FILE\"")
        quiescent_wait = cleanup.index("wait_for_marker \"$QUIESCENT_FILE\" 30", suite_complete)
        teardown = cleanup.index("//rust/integration-db:teardown_db", quiescent_wait)
        end = cleanup.index("END_NS=", teardown)
        stop = cleanup.index("touch \"$STOP_FILE\"", end)
        observer_wait = cleanup.index("wait \"$OBSERVER_PID\"", stop)
        self.assertLess(suite_complete, quiescent_wait)
        self.assertLess(quiescent_wait, teardown)
        self.assertLess(teardown, end)
        self.assertLess(end, stop)
        self.assertLess(stop, observer_wait)

        self.assertIn('exit "$SUITE_STATUS"', cleanup)
        self.assertIn('exit "$OBSERVER_STATUS"', cleanup)
        self.assertIn('exit "$TEARDOWN_STATUS"', cleanup)
        self.assertLess(cleanup.index('exit "$SUITE_STATUS"'), cleanup.index('exit "$OBSERVER_STATUS"'))
        self.assertLess(cleanup.index('exit "$OBSERVER_STATUS"'), cleanup.index('exit "$TEARDOWN_STATUS"'))

    def test_fixed_external_resource_sources_are_serial_data_cases(self):
        self.assertEqual(FIXED_EXTERNAL_RESOURCE_PATHS, fixed_external_resource_sources())

        for relative_path in FIXED_EXTERNAL_RESOURCE_PATHS:
            source = ROOT / "elixir/serviceradar_core" / relative_path
            self.assertEqual(
                1,
                source.read_text(encoding="utf-8").count(
                    "use ServiceRadar.DataCase, async: false"
                ),
                source,
            )

    def test_core_integration_targets_share_the_bounded_environment(self):
        core_build = CORE_BUILD.read_text(encoding="utf-8")
        generated_targets = core_build[core_build.index("integration_tests_{}") :]
        unit_tests = core_build[core_build.index('name = "unit_tests"') : core_build.index("integration_tests_{}")]

        self.assertIn("env = integration_test_env(shard)", generated_targets)
        self.assertNotIn("SERVICERADAR_INTEGRATION_MAX_CASES", unit_tests)

    def test_integration_cap_is_parsed_before_starting_ex_unit(self):
        source = TEST_HELPER.read_text(encoding="utf-8")
        selection = 'if System.get_env("SERVICERADAR_ONLY_INTEGRATION") in ["1", "true", "TRUE"] do'
        branch = integration_only_branch()
        outside_branch = source[: source.index(selection)] + source[source.index(branch) + len(branch) :]

        parser_assignment = branch.index("integration_max_cases =")
        parser_call = branch.index("ServiceRadar.TestSupport.integration_max_cases!", parser_assignment)
        environment_read = branch.index(
            'System.get_env("SERVICERADAR_INTEGRATION_MAX_CASES")', parser_call
        )
        ex_unit_start = branch.index("ExUnit.start(", environment_read)
        max_cases_option = branch.index("max_cases: integration_max_cases", ex_unit_start)

        self.assertLess(branch.index(selection), parser_assignment)
        self.assertLess(parser_assignment, parser_call)
        self.assertLess(parser_call, environment_read)
        self.assertLess(environment_read, ex_unit_start)
        self.assertLess(ex_unit_start, max_cases_option)
        self.assertNotIn("integration_max_cases!", outside_branch)
        self.assertNotIn("max_cases: integration_max_cases", outside_branch)

    def test_large_ingestion_gate_has_dedicated_sources_and_database(self):
        core_build = CORE_BUILD.read_text(encoding="utf-8")
        integration_db_build = OBSERVER_BUILD.read_text(encoding="utf-8")
        shard_build = INTEGRATION_SHARDS.read_text(encoding="utf-8")
        ordinary_router = ORDINARY_RESULTS_ROUTER.read_text(encoding="utf-8")
        release_router = RELEASE_RESULTS_ROUTER.read_text(encoding="utf-8")
        release_cardinality = RELEASE_IDENTIFIER_CARDINALITY.read_text(encoding="utf-8")
        all_test_sources = core_build[
            core_build.index("ALL_TEST_SRCS =") : core_build.index(
                "INTEGRATION_SHARD_SRCS ="
            )
        ]
        runtime_data = core_build[
            core_build.index("INTEGRATION_RUNTIME_DATA =") : core_build.index(
                "filegroup(\n    name = \"srcs\""
            )
        ]
        generated_targets = core_build[core_build.index('name = "integration_tests_{}"') :]
        release_target = named_starlark_rule(
            core_build, "ex_unit_test", "large_ingestion_release_gate"
        )
        ordinary_provision = named_starlark_rule(
            integration_db_build, "rust_test", "provision_db"
        )
        release_provision = named_starlark_rule(
            integration_db_build, "rust_test", "provision_db_large_ingestion"
        )

        self.assertNotIn(
            'test "large Armis sync chunks route through results router into inventory"',
            ordinary_router,
        )
        self.assertIn(
            'test "large Armis sync chunks route through results router into inventory"',
            release_router,
        )
        self.assertIn("50_000", release_router)
        self.assertIn(
            "defmodule ServiceRadar.ResultsRouterLargeIngestionReleaseGateTest",
            release_router,
        )
        self.assertIn("use ServiceRadar.DataCase, async: false", release_router)
        self.assertIn("@moduletag :integration", release_router)
        self.assertIn("@moduletag :large_ingestion", release_router)
        for retained in (
            "setup_all do",
            "setup do",
            "defp system_actor do",
            "defp large_ingestion_device_count do",
            "defp large_ingestion_chunk_size do",
            "defp ceil_div(left, right)",
            "defp large_ingestion_ip(device_number)",
            "defp scalar_count!(sql, params)",
        ):
            self.assertIn(retained, release_router)
        self.assertIn(
            'test "identifier rows stay bounded across churned ingest rounds"',
            release_cardinality,
        )
        self.assertIn("use ServiceRadar.DataCase, async: false", release_cardinality)
        self.assertIn("@moduletag :integration", release_cardinality)
        self.assertIn("@moduletag :large_ingestion", release_cardinality)
        self.assertIn("@devices 500", release_cardinality)
        self.assertIn("@rounds 3", release_cardinality)
        self.assertIn(
            "//elixir/serviceradar_core:large_ingestion_release_gate",
            release_cardinality,
        )
        self.assertNotIn(
            '"test/serviceradar/results_router_integration_test.exs"',
            shard_build[shard_build.index("_HEAVY_SRCS =") :],
        )

        self.assertIn('"test/release_gates/**"', all_test_sources)
        self.assertIn('"test/release_gates/**"', runtime_data)
        self.assertIn('"test/**/*_test.exs"', runtime_data)
        self.assertIn("INTEGRATION_RUNTIME_DATA", generated_targets)

        self.assertEqual(1, core_build.count('name = "large_ingestion_release_gate"'))
        self.assertIn('size = "enormous"', release_target)
        self.assertIn('"test/release_gates/large_ingestion/*_test.exs"', release_target)
        self.assertIn("allow_empty = False", release_target)
        self.assertIn("data = INTEGRATION_RUNTIME_DATA", release_target)
        self.assertIn('"test/test_helper.exs"', release_target)
        self.assertLess(
            release_target.index('"test/db/integration_env.exs"'),
            release_target.index('"../../build/elixir_test_config_loader.exs"'),
        )
        self.assertIn("include: [:integration, :requires_app]", integration_only_branch())
        self.assertIn('"SERVICERADAR_ONLY_INTEGRATION": "1"', release_target)
        self.assertIn(
            '"SERVICERADAR_INTEGRATION_MAX_CASES": "1"', release_target
        )
        self.assertIn(
            '"SERVICERADAR_TEST_DB_SHARD": LARGE_INGESTION_DB_SHARD',
            release_target,
        )
        self.assertIn(
            '"SERVICERADAR_LARGE_INGESTION_DEVICE_COUNT": "50000"',
            release_target,
        )
        self.assertIn(
            '"SERVICERADAR_LARGE_INGESTION_CHUNK_SIZE": "1000"', release_target
        )
        self.assertIn('"integration_test",', release_target)
        self.assertIn('"large_ingestion_test",', release_target)
        self.assertIn("target_compatible_with = requires_shared_fixture()", release_target)

        self.assertEqual(1, integration_db_build.count('name = "provision_db_large_ingestion"'))
        self.assertIn('srcs = ["tests/provision_db_test.rs"]', release_provision)
        self.assertIn('crate_root = "tests/provision_db_test.rs"', release_provision)
        self.assertIn(
            'data = FIXTURE_DATA + ["//elixir/serviceradar_core:migrations"]',
            release_provision,
        )
        self.assertIn(
            '"SERVICERADAR_TEST_DB_SHARDS": LARGE_INGESTION_DB_SHARD',
            release_provision,
        )
        self.assertIn("target_compatible_with = requires_shared_fixture()", release_provision)
        self.assertIn(
            '"SERVICERADAR_TEST_DB_SHARDS": ",".join(integration_shard_names())',
            ordinary_provision,
        )
        self.assertNotIn("LARGE_INGESTION_DB_SHARD", ordinary_provision)


if __name__ == "__main__":
    if sys.argv[1:] == ["--hash-integration-benchmark"]:
        print(harness_hash())
    else:
        unittest.main()
