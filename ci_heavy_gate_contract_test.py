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


if __name__ == "__main__":
    if sys.argv[1:] == ["--hash-integration-benchmark"]:
        print(harness_hash())
    else:
        unittest.main()
