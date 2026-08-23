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
RELEASE_WORKFLOW = ROOT / ".github/workflows/release.yml"
RELEASE_GATE_MARKER = ROOT / "build/ci/large_ingestion_gate_contract.v1"
RELEASE_GATE_BUILD = ROOT / "build/ci/BUILD.bazel"
RELEASE_GATE_LIBRARY = ROOT / "build/ci/large_ingestion_gate.py"
RELEASE_GATE_CLI = ROOT / "build/ci/wait_for_large_ingestion_gate.py"
RELEASE_GATE_TEST = ROOT / "build/ci/wait_for_large_ingestion_gate_test.py"
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
ASYNC_SAFE_SRCS = (
    "test/integration/advisory_feed_loader_integration_test.exs",
    "test/integration/secret_broker_audit_integration_test.exs",
)
SERIAL_COMPOSITE_CHECK_SRCS = (
    "test/serviceradar/composite_checks/composite_check_test.exs",
    "test/serviceradar/composite_checks/composite_check_rule_test.exs",
    "test/serviceradar/composite_checks/composite_check_input_test.exs",
    "test/serviceradar/composite_checks/device_composite_check_result_test.exs",
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


def named_action(name: str) -> str:
    workflow = WORKFLOW.read_text(encoding="utf-8")
    match = re.search(
        rf'^  - name: "{re.escape(name)}"\n(?P<block>.*?)(?=^  - name:|\Z)',
        workflow,
        re.MULTILINE | re.DOTALL,
    )
    if not match:
        raise AssertionError(f"{name} action is missing")
    return match.group(0)


def integration_benchmark_action() -> str:
    return named_action("IntegrationBenchmark")


def database_lifecycle_shell(action: str) -> str:
    marker = "      - run: |\n"
    starts = [match.end() for match in re.finditer(re.escape(marker), action)]
    if len(starts) != 1:
        raise AssertionError(
            f"expected exactly one database lifecycle shell, found {len(starts)}"
        )

    body = []
    for line in action[starts[0] :].splitlines(keepends=True):
        if line.strip() == "":
            body.append(line)
        elif line.startswith("          "):
            body.append(line[10:])
        else:
            break
    return "".join(body)


def measured_database_lifecycle_shell(action: str) -> str:
    shell = database_lifecycle_shell(action)
    match = re.search(r"^RUN_ID=", shell, re.MULTILINE)
    if not match:
        raise AssertionError("measured RUN_ID boundary is missing")
    return shell[match.start() :]


def normalized_shell_lines(shell: str) -> tuple[str, ...]:
    logical_lines = []
    pending = ""
    for raw_line in shell.splitlines():
        stripped = raw_line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        pending = f"{pending} {stripped}".strip()
        if pending.endswith("\\"):
            pending = pending[:-1].rstrip()
            continue
        logical_lines.append(" ".join(pending.split()))
        pending = ""
    if pending:
        logical_lines.append(" ".join(pending.split()))
    return tuple(logical_lines)


def shell_command_segments(line: str) -> tuple[str, ...]:
    """Split one logical shell line at unquoted command terminators."""
    segments = []
    start = 0
    index = 0
    quote = None
    while index < len(line):
        character = line[index]
        if character == "\\" and quote != "'":
            index += 2
            continue
        if quote:
            if character == quote:
                quote = None
            index += 1
            continue
        if character in ("'", '"'):
            quote = character
            index += 1
            continue

        terminator = next(
            (
                candidate
                for candidate in (";;", "&&", "||", ";")
                if line.startswith(candidate, index)
            ),
            None,
        )
        if terminator:
            segment = line[start:index].strip()
            if segment:
                segments.append(segment)
            index += len(terminator)
            start = index
            continue
        index += 1

    segment = line[start:].strip()
    if segment:
        segments.append(segment)
    return tuple(segments)


def is_executable_bazel_test(segment: str, start: int) -> bool:
    """Reject mentions of ``bazel test`` that are arguments to another command."""
    prefix = segment[:start].strip()
    if not prefix:
        return True
    if prefix.endswith((")", "$(", "(")):
        return True
    if re.search(r"(?:^|\s)(?:if|then|elif|while|until|do|!|time)$", prefix):
        return True
    prefix_tokens = prefix.split()
    return bool(prefix_tokens) and all(
        re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", token)
        for token in prefix_tokens
    )


def normalized_bazel_test_commands(action: str) -> tuple[str, ...]:
    """Inventory every literal executable ``bazel test`` in lifecycle order."""
    commands = []
    pattern = re.compile(r"(?:command\s+)?bazel\s+test\b")
    for line in normalized_shell_lines(database_lifecycle_shell(action)):
        for segment in shell_command_segments(line):
            match = pattern.search(segment)
            if not match or not is_executable_bazel_test(segment, match.start()):
                continue
            command = segment[match.start() :]
            command = re.sub(r"^command\s+", "", command, count=1)
            command = re.sub(
                r"\$\{(PREFLIGHT_FLAGS|FLAGS)\}",
                lambda variable: f"${variable.group(1)}",
                command,
            )
            commands.append(" ".join(command.split()))
    return tuple(commands)


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


def named_release_step(name: str) -> str:
    workflow = RELEASE_WORKFLOW.read_text(encoding="utf-8")
    match = re.search(
        rf"^      - name: {re.escape(name)}\n(?P<body>.*?)(?=^      - name:|^  [a-zA-Z_]|\Z)",
        workflow,
        re.MULTILINE | re.DOTALL,
    )
    if not match:
        raise AssertionError(f"release step {name} is missing")
    return match.group(0)


def release_permissions() -> tuple[str, ...]:
    workflow = RELEASE_WORKFLOW.read_text(encoding="utf-8")
    match = re.search(r"^permissions:\n(?P<body>(?:  .+\n)+)", workflow, re.MULTILINE)
    if not match:
        raise AssertionError("release workflow permissions are missing")
    return tuple(line.strip() for line in match.group("body").splitlines())


def ordinary_integration_target_comprehension(core_build: str) -> str:
    start = core_build.index(
        '[\n    ex_unit_test(\n        name = "integration_tests_{}"'
    )
    end = core_build.index(
        'ex_unit_test(\n    name = "large_ingestion_release_gate"', start
    )
    return core_build[start:end]


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


class WorkflowIntegrationLifecycleContractTest(unittest.TestCase):
    preflight_migrate_command = (
        "bazel test $PREFLIGHT_FLAGS "
        "//elixir/serviceradar_core:migrate_template"
    )
    preflight_migrate_arm = (
        '*"migration(s) pending"*) bazel test $PREFLIGHT_FLAGS '
        "//elixir/serviceradar_core:migrate_template ;;"
    )
    preflight_pending_arm = (
        '*"migration(s) pending"*) echo "template remains pending after preflight" '
        ">&2; exit 1 ;;"
    )
    measured_pending_arm = (
        '*"migration(s) pending"*) echo "template changed during measured lifecycle" '
        ">&2; exit 1 ;;"
    )
    preflight_prepare = (
        'preflight="$(bazel run -c opt --config=ci '
        "--//build:enable_integration_tests --//build:run_id=$PREFLIGHT_RUN_ID "
        '//rust/integration-db:prepare_template)"'
    )
    ordinary_suite = (
        "bazel test $FLAGS //... "
        "--test_tag_filters=integration_test,-large_ingestion_test,-acceptance_test"
    )
    heavy_provision = (
        "bazel test $FLAGS "
        "//rust/integration-db:provision_db_large_ingestion"
    )
    heavy_suite = (
        "bazel test $FLAGS "
        "//elixir/serviceradar_core:large_ingestion_release_gate"
    )
    fixture_setup = (
        "bazel run -c opt --config=ci --//build:enable_integration_tests "
        "--//build:run_id=$RUN_ID //:buildbuddy_setup_fixture_env"
    )
    observer_start = (
        "bazel run -c opt --config=ci --//build:enable_integration_tests "
        "--//build:run_id=$RUN_ID //rust/integration-db:observe_connections -- "
        '--ready-file "$READY_FILE" --suite-complete-file "$SUITE_COMPLETE_FILE" '
        '--quiescent-file "$QUIESCENT_FILE" --stop-file "$STOP_FILE" '
        "--max-seconds 1800 &"
    )
    sweep = "bazel test $FLAGS //rust/integration-db:sweep_stale_dbs"
    current_prepare = (
        'template="$(bazel run -c opt --config=ci '
        "--//build:enable_integration_tests --//build:run_id=$RUN_ID "
        '//rust/integration-db:prepare_template)"'
    )

    def assert_cache_flags(self, action_name: str) -> None:
        action = named_action(action_name)
        shell = database_lifecycle_shell(action)
        measured = measured_database_lifecycle_shell(action)
        preflight_flags_start = shell.index('PREFLIGHT_FLAGS="')
        preflight_flags_end = shell.index('preflight="$(bazel', preflight_flags_start)
        measured_flags_start = measured.index('FLAGS="-c opt --config=ci')
        measured_flags_end = measured.index("OBSERVER_DIR=", measured_flags_start)
        flag_blocks = {
            "preflight": shell[preflight_flags_start:preflight_flags_end],
            "measured": measured[measured_flags_start:measured_flags_end],
        }
        unexpected_counts = {
            phase: {
                flag: block.count(flag)
                for flag in (
                    "--nocache_test_results",
                    "--noremote_upload_local_results",
                )
                if block.count(flag) != 1
            }
            for phase, block in flag_blocks.items()
        }
        self.assertEqual(
            {},
            {
                phase: counts
                for phase, counts in unexpected_counts.items()
                if counts
            },
        )

    def assert_exact_measured_execution_order(
        self,
        action: str,
        provision_command: str,
        suite_command: str,
    ) -> None:
        measured = measured_database_lifecycle_shell(action)
        lines = normalized_shell_lines(measured)
        wait = "wait_for_observer_ready 30 || exit 1"
        self.assertEqual(1, lines.count(wait))
        self.assertNotIn("wait_for_observer_ready 30 || true", lines)
        self.assertEqual(
            1,
            sum("//rust/integration-db:prepare_template" in line for line in lines),
        )
        self.assertNotIn("//elixir/serviceradar_core:migrate_template", measured)

        expected = (
            self.fixture_setup,
            self.observer_start,
            wait,
            self.sweep,
            self.current_prepare,
            self.measured_pending_arm,
            provision_command,
            suite_command,
        )
        positions = []
        for command in expected:
            self.assertEqual(1, lines.count(command), command)
            positions.append(lines.index(command))
        self.assertEqual(sorted(positions), positions)

    def assert_preflight_command_order(self, action: str) -> None:
        shell = database_lifecycle_shell(action)
        measured_start = re.search(r"^RUN_ID=", shell, re.MULTILINE)
        self.assertIsNotNone(measured_start)
        preflight = shell[: measured_start.start()]
        lines = normalized_shell_lines(preflight)
        prepare_positions = [
            index for index, line in enumerate(lines) if line == self.preflight_prepare
        ]
        self.assertEqual(2, len(prepare_positions))
        self.assertEqual(1, lines.count(self.preflight_migrate_arm))
        self.assertEqual(1, lines.count(self.preflight_pending_arm))
        conditional_migrate = lines.index(self.preflight_migrate_arm)
        pending_check = lines.index(self.preflight_pending_arm)
        self.assertLess(prepare_positions[0], conditional_migrate)
        self.assertLess(conditional_migrate, prepare_positions[1])
        self.assertLess(prepare_positions[1], pending_check)

    def test_task6_database_flags_disable_cache_and_remote_upload(self):
        for action_name in ("BazelCI", "LargeIngestionGate"):
            with self.subTest(action=action_name):
                self.assert_cache_flags(action_name)

    def test_bazel_test_command_extractor_inventories_every_literal_form(self):
        synthetic_action = """  - name: "Synthetic"
    steps:
      - run: |
          case "$state" in
            pending) bazel test $PREFLIGHT_FLAGS //example:preflight ;;
          esac
          command   bazel   test   ${FLAGS}   //example:braced && bazel test --config=ci //example:inline
          bazel test ${PREFLIGHT_FLAGS} //example:preflight-braced; command bazel test $FLAGS //example:after-semicolon
"""
        self.assertEqual(
            (
                "bazel test $PREFLIGHT_FLAGS //example:preflight",
                "bazel test $FLAGS //example:braced",
                "bazel test --config=ci //example:inline",
                "bazel test $PREFLIGHT_FLAGS //example:preflight-braced",
                "bazel test $FLAGS //example:after-semicolon",
            ),
            normalized_bazel_test_commands(synthetic_action),
        )

    def assert_common_measured_lifecycle(
        self,
        action: str,
        provision_command: str,
        suite_command: str,
    ) -> None:
        for required in (
            "export BAZEL_PROFILE=ci",
            "export SERVICERADAR_ENV=ci",
            "--strategy=TestRunner=local",
            "--//build:enable_integration_tests",
            "--//build:run_id=$RUN_ID",
            "--flaky_test_attempts=1",
            "--test_output=all",
            "--test_env=SERVICERADAR_TEST_SLOWEST=15",
            "od -An -tx1 -N4 /dev/urandom",
            "export RUN_ID",
            "//:buildbuddy_setup_fixture_env",
            "//rust/integration-db:observe_connections",
            '--ready-file "$READY_FILE"',
            '--suite-complete-file "$SUITE_COMPLETE_FILE"',
            '--quiescent-file "$QUIESCENT_FILE"',
            '--stop-file "$STOP_FILE"',
            "--max-seconds 1800",
            provision_command,
            suite_command,
        ):
            self.assertIn(required, action)

        measured_start = action.index("\n          RUN_ID=")
        measured = action[measured_start:]
        flags = measured.index('FLAGS="-c opt --config=ci')
        cleanup = measured.index("cleanup() {")
        self.assertLess(flags, cleanup)
        for measured_flag in (
            "--strategy=TestRunner=local",
            "--//build:enable_integration_tests",
            "--//build:run_id=$RUN_ID",
            "--test_env=SERVICERADAR_ENV=ci",
            "--flaky_test_attempts=1",
            "--test_output=all",
            "--test_env=SERVICERADAR_TEST_SLOWEST=15",
        ):
            self.assertIn(measured_flag, measured[flags:cleanup])
        for secret in (
            "SERVICERADAR_SECRET_DATABASE_PASSWORD",
            "SERVICERADAR_SECRET_DATABASE_ADMIN_PASSWORD",
            "SERVICERADAR_SECRET_DGRAPH_ADMIN_PASSWORD",
        ):
            self.assertIn(f"--test_env={secret}", measured[flags:cleanup])
        self.assertIn('FLAGS="$FLAGS $SERVICERADAR_TEST_ENV_FLAGS"', measured)

    def assert_preflight_and_clock_contract(self, action: str) -> None:
        for required in (
            "PREFLIGHT_RUN_ID=",
            "PREFLIGHT_ENV_FILE=",
            'chmod 600 "$PREFLIGHT_ENV_FILE"',
            'SERVICERADAR_FIXTURE_ENV_FILE="$PREFLIGHT_ENV_FILE"',
            'trap \'rm -f "$PREFLIGHT_ENV_FILE"\' EXIT',
            "template remains pending after preflight",
            "template changed during measured lifecycle",
        ):
            self.assertIn(required, action)

        preflight_start = action.index("PREFLIGHT_RUN_ID=")
        measured_start = action.index("\n          RUN_ID=", preflight_start)
        start_ns = action.index("START_NS=", measured_start)
        fixture_setup = action.index("//:buildbuddy_setup_fixture_env", start_ns)
        self.assertLess(preflight_start, measured_start)
        self.assertLess(measured_start, start_ns)
        self.assertLess(start_ns, fixture_setup)
        self.assertRegex(
            action[start_ns:fixture_setup + len("//:buildbuddy_setup_fixture_env")],
            r'START_NS="\$\(date \+%s%N\)"\n\s+bazel run .*//:buildbuddy_setup_fixture_env',
        )

        preflight = action[preflight_start:measured_start]
        measured = action[start_ns:]
        self.assertEqual(2, preflight.count("//rust/integration-db:prepare_template"))
        self.assertEqual(1, preflight.count("//elixir/serviceradar_core:migrate_template"))
        self.assertEqual(1, measured.count("//rust/integration-db:prepare_template"))
        self.assertNotIn("//elixir/serviceradar_core:migrate_template", measured)

    def assert_observer_and_cleanup_contract(self, action: str) -> None:
        for marker, basename in (
            ("READY_FILE", "ready"),
            ("SUITE_COMPLETE_FILE", "suite-complete"),
            ("QUIESCENT_FILE", "quiescent"),
            ("STOP_FILE", "stop"),
        ):
            self.assertIn(f'{marker}="$OBSERVER_DIR/{basename}"', action)
            self.assertIn(f'test ! -e "${marker}"', action)

        for required in (
            'OBSERVER_DIR="$(mktemp -d "${TMPDIR:-/tmp}/serviceradar-observer.XXXXXX")"',
            'chmod 600 "$SERVICERADAR_FIXTURE_ENV_FILE"',
            "wait_for_observer_ready 30",
            'kill -0 "$OBSERVER_PID"',
            'touch "$SUITE_COMPLETE_FILE"',
            'wait_for_marker "$QUIESCENT_FILE" 30',
            '//rust/integration-db:teardown_db',
            'touch "$STOP_FILE"',
            'wait "$OBSERVER_PID"',
            'rm -f "$SERVICERADAR_FIXTURE_ENV_FILE"',
            'rm -rf "$OBSERVER_DIR"',
        ):
            self.assertIn(required, action)

        cleanup = action[action.index("cleanup() {") :]
        cleanup_lines = normalized_shell_lines(cleanup)
        teardown_window = (
            "bazel test $FLAGS //rust/integration-db:teardown_db",
            "TEARDOWN_STATUS=$?",
            'END_NS="$(date +%s%N)"',
        )
        self.assertEqual(
            1,
            sum(
                cleanup_lines[index : index + len(teardown_window)]
                == teardown_window
                for index in range(len(cleanup_lines) - len(teardown_window) + 1)
            ),
        )
        original = cleanup.index("ORIGINAL_STATUS=$?")
        disable_trap = cleanup.index("trap - EXIT", original)
        nonfatal = cleanup.index("set +e", disable_trap)
        suite_complete = cleanup.index('touch "$SUITE_COMPLETE_FILE"', nonfatal)
        quiescent = cleanup.index(
            'wait_for_marker "$QUIESCENT_FILE" 30', suite_complete
        )
        teardown = cleanup.index("//rust/integration-db:teardown_db", quiescent)
        teardown_status = cleanup.index("TEARDOWN_STATUS=$?", teardown)
        end_ns = cleanup.index("END_NS=", teardown_status)
        stop = cleanup.index('touch "$STOP_FILE"', end_ns)
        observer_wait = cleanup.index('wait "$OBSERVER_PID"', stop)
        self.assertLess(original, disable_trap)
        self.assertLess(disable_trap, nonfatal)
        self.assertLess(suite_complete, quiescent)
        self.assertLess(quiescent, teardown)
        self.assertLess(teardown, teardown_status)
        self.assertLess(teardown_status, end_ns)
        self.assertLess(end_ns, stop)
        self.assertLess(stop, observer_wait)
        self.assertRegex(
            cleanup[teardown:],
            r"TEARDOWN_STATUS=\$\?\n\s+END_NS=",
        )
        self.assertIn("LIFECYCLE_NS=$((END_NS - START_NS))", cleanup)
        self.assertIn("suite_status=$SUITE_STATUS", cleanup)
        self.assertIn("observer_status=$OBSERVER_STATUS", cleanup)
        self.assertIn("teardown_status=$TEARDOWN_STATUS", cleanup)
        self.assertIn("SUITE_STATUS=$ORIGINAL_STATUS", cleanup)

        status_init = action.index("SUITE_STATUS=0")
        cleanup_definition = action.index("cleanup() {", status_init)
        trap_install = action.index("trap cleanup EXIT", cleanup_definition)
        self.assertLess(status_init, cleanup_definition)
        self.assertLess(cleanup_definition, trap_install)

        suite_exit = cleanup.index('exit "$SUITE_STATUS"')
        observer_exit = cleanup.index('exit "$OBSERVER_STATUS"', suite_exit)
        teardown_exit = cleanup.index('exit "$TEARDOWN_STATUS"', observer_exit)
        self.assertLess(suite_exit, observer_exit)
        self.assertLess(observer_exit, teardown_exit)

    def assert_teardown_suffix_mutations_are_rejected(self, action: str) -> None:
        teardown = "bazel test $FLAGS //rust/integration-db:teardown_db"
        self.assertEqual(1, action.count(teardown))
        for suffix in (" || true", "; true"):
            with self.subTest(teardown_suffix=suffix):
                mutated = action.replace(teardown, f"{teardown}{suffix}", 1)
                with self.assertRaises(AssertionError):
                    self.assert_observer_and_cleanup_contract(mutated)

    def test_bazel_ci_keeps_its_runner_trigger_and_measures_the_ordinary_suite(self):
        action = named_action("BazelCI")
        header = action[: action.index("    steps:")]
        self.assertIn('pull_request:\n        branches:\n          - "staging"', header)
        self.assertNotIn("push:", header)
        self.assertNotIn("schedule:", header)
        for required in (
            'pool: "workflows"',
            "container_image: \"docker://registry.carverauto.dev/serviceradar/buildbuddy-workflow-runner:v1.0.24.3\"",
            "self_hosted: true",
            'OSFamily: "linux"',
            'Arch: "amd64"',
            'dockerNetwork: "bridge"',
            'memory: "50GB"',
            'disk: "40GB"',
        ):
            self.assertIn(required, action)

        self.assert_common_measured_lifecycle(
            action,
            "bazel test $FLAGS //rust/integration-db:provision_db",
            self.ordinary_suite,
        )
        self.assertEqual(1, action.count(self.ordinary_suite))
        self.assertNotIn(
            "bazel test $FLAGS //... "
            "--test_tag_filters=integration_test,-acceptance_test",
            action,
        )
        self.assert_preflight_and_clock_contract(action)
        self.assert_preflight_command_order(action)
        self.assert_exact_measured_execution_order(
            action,
            "bazel test $FLAGS //rust/integration-db:provision_db",
            self.ordinary_suite,
        )
        self.assert_observer_and_cleanup_contract(action)
        self.assert_teardown_suffix_mutations_are_rejected(action)
        commands = normalized_bazel_test_commands(action)
        self.assertEqual(
            (
                self.preflight_migrate_command,
                "bazel test $FLAGS //rust/integration-db:teardown_db",
                self.sweep,
                "bazel test $FLAGS //rust/integration-db:provision_db",
                self.ordinary_suite,
            ),
            commands,
        )
        self.assertEqual(
            (self.ordinary_suite,),
            tuple(command for command in commands if "$FLAGS //..." in command),
        )

    def test_large_ingestion_gate_has_exact_independent_trigger(self):
        action = named_action("LargeIngestionGate")
        header = action[: action.index("    steps:")]
        self.assertIn(
            '    triggers:\n'
            '      push:\n'
            '        branches:\n'
            '          - "staging"\n'
            '        tags:\n'
            '          - "v*"\n'
            '      schedule:\n'
            '        crons:\n'
            '          - "0 2 * * *"\n',
            header,
        )
        self.assertNotIn("pull_request:", header)
        branches = header[header.index("branches:") : header.index("tags:")]
        tags = header[header.index("tags:") : header.index("schedule:")]
        self.assertNotIn('"v*"', branches)
        self.assertIn('"v*"', tags)

    def test_large_ingestion_gate_copies_runner_fixture_and_credential_scope(self):
        action = named_action("LargeIngestionGate")
        for required in (
            'OCI_REGISTRY: "registry.carverauto.dev"',
            'OCI_AUTH_REQUIRED: "1"',
            'SRQL_FIXTURE_CA_URL: "http://srql-fixture-ca-incluster.srql-fixtures.svc.cluster.local/ca.crt"',
            "self_hosted: true",
            'pool: "workflows"',
            "container_image: \"docker://registry.carverauto.dev/serviceradar/buildbuddy-workflow-runner:v1.0.24.3\"",
            'OSFamily: "linux"',
            'Arch: "amd64"',
            'dockerNetwork: "bridge"',
            'memory: "50GB"',
            'disk: "40GB"',
            "//:buildbuddy_setup_docker_auth",
        ):
            self.assertIn(required, action)
        self.assertNotIn("BUILDBUDDY_API_KEY", action)
        self.assertNotIn("GITHUB_TOKEN", action)
        self.assertNotIn("gh api", action)
        self.assertNotIn("set -x", action)

    def test_large_ingestion_gate_runs_only_the_full_strength_focused_pair(self):
        action = named_action("LargeIngestionGate")
        self.assert_common_measured_lifecycle(
            action,
            self.heavy_provision,
            self.heavy_suite,
        )
        self.assertEqual(1, action.count(self.heavy_provision))
        self.assertEqual(1, action.count(self.heavy_suite))
        self.assertNotIn(
            "bazel test $FLAGS //rust/integration-db:provision_db\n", action
        )
        self.assertNotRegex(
            action,
            r"bazel test \$FLAGS //\.\.\.\s+--test_tag_filters=integration_test",
        )
        for lowered_workload in (
            "SERVICERADAR_LARGE_INGESTION_DEVICE_COUNT",
            "SERVICERADAR_LARGE_INGESTION_CHUNK_SIZE",
            "SERVICERADAR_IDENTIFIER_CARDINALITY_DEVICE_COUNT",
            "SERVICERADAR_IDENTIFIER_CARDINALITY_ROUNDS",
        ):
            self.assertNotIn(lowered_workload, action)
        self.assert_preflight_and_clock_contract(action)
        self.assert_preflight_command_order(action)
        self.assert_exact_measured_execution_order(
            action,
            self.heavy_provision,
            self.heavy_suite,
        )
        self.assert_observer_and_cleanup_contract(action)
        self.assert_teardown_suffix_mutations_are_rejected(action)
        commands = normalized_bazel_test_commands(action)
        self.assertEqual(
            (
                self.preflight_migrate_command,
                "bazel test $FLAGS //rust/integration-db:teardown_db",
                self.sweep,
                self.heavy_provision,
                self.heavy_suite,
            ),
            commands,
        )
        self.assertFalse(any("$FLAGS //..." in command for command in commands))

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

    def test_async_safe_sources_are_explicitly_audited_data_cases(self):
        self.assertTrue(set(ASYNC_SAFE_SRCS).isdisjoint(FIXED_EXTERNAL_RESOURCE_PATHS))

        prohibited_semantics = (
            "sandbox: :unboxed",
            "Application.put_env",
            "Application.delete_env",
            "TRUNCATE",
            "CREATE TABLE",
            "REFRESH MATERIALIZED",
            "Gnat.",
            "Nats",
        )

        for relative_path in ASYNC_SAFE_SRCS:
            source = (ROOT / "elixir/serviceradar_core" / relative_path).read_text(
                encoding="utf-8"
            )
            self.assertEqual(1, source.count("use ServiceRadar.DataCase, async: true"))

            for prohibited in prohibited_semantics:
                self.assertNotIn(prohibited, source, relative_path)

    def test_composite_check_sources_remain_serial_data_cases(self):
        self.assertTrue(set(SERIAL_COMPOSITE_CHECK_SRCS).isdisjoint(ASYNC_SAFE_SRCS))
        self.assertTrue(
            set(SERIAL_COMPOSITE_CHECK_SRCS).isdisjoint(FIXED_EXTERNAL_RESOURCE_PATHS)
        )

        for relative_path in SERIAL_COMPOSITE_CHECK_SRCS:
            source = (ROOT / "elixir/serviceradar_core" / relative_path).read_text(
                encoding="utf-8"
            )
            self.assertEqual(1, source.count("use ServiceRadar.DataCase, async: false"))
            self.assertEqual(0, source.count("use ServiceRadar.DataCase, async: true"))

    def test_core_integration_targets_share_the_bounded_environment(self):
        core_build = CORE_BUILD.read_text(encoding="utf-8")
        generated_targets = ordinary_integration_target_comprehension(core_build)
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
        generated_targets = ordinary_integration_target_comprehension(core_build)
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
        self.assertEqual(
            1, generated_targets.count("data = INTEGRATION_RUNTIME_DATA")
        )

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


class ReleaseLargeIngestionQualificationContractTest(unittest.TestCase):
    qualifier_step = """      - name: Wait for large-ingestion gate
        env:
          RELEASE_COMMIT: ${{ steps.source.outputs.commit }}
        run: |
          set -euo pipefail
          bazel run ${BAZEL_BUILD_FLAGS} //build/ci:wait_for_large_ingestion_gate -- \\
            --repository "${GITHUB_REPOSITORY}" \\
            --commit "${RELEASE_COMMIT}" \\
            --base-ref origin/staging \\
            --token-env GH_TOKEN \\
            --timeout-seconds 1800 \\
            --poll-seconds 15 \\
            --target-url-prefix https://carverauto.buildbuddy.io/invocation/

"""

    def test_marker_and_bazel_contract_are_atomic_and_exact(self):
        self.assertEqual(
            b"large-ingestion-gate-contract-v1\n", RELEASE_GATE_MARKER.read_bytes()
        )
        build = RELEASE_GATE_BUILD.read_text(encoding="utf-8")
        library = named_starlark_rule(build, "py_library", "large_ingestion_gate")
        binary = named_starlark_rule(
            build, "py_binary", "wait_for_large_ingestion_gate"
        )
        test = named_starlark_rule(
            build, "py_test", "wait_for_large_ingestion_gate_test"
        )
        self.assertEqual(1, build.count('name = "large_ingestion_gate"'))
        self.assertEqual(1, build.count('name = "wait_for_large_ingestion_gate"'))
        self.assertEqual(1, build.count('name = "wait_for_large_ingestion_gate_test"'))
        self.assertIn('srcs = ["large_ingestion_gate.py"]', library)
        self.assertIn('srcs = ["wait_for_large_ingestion_gate.py"]', binary)
        self.assertIn('srcs = ["wait_for_large_ingestion_gate_test.py"]', test)
        exports = build[build.index("exports_files([") : build.index("])\n", build.index("exports_files(["))]
        self.assertIn('"large_ingestion_gate_contract.v1"', exports)
        self.assertIn('data = ["large_ingestion_gate_contract.v1"]', binary)
        self.assertIn('data = ["large_ingestion_gate_contract.v1"]', test)
        self.assertNotIn("no-sandbox", build)
        self.assertNotIn("no-remote", build)

    def test_python_adapters_are_argv_only_and_fail_closed(self):
        library = RELEASE_GATE_LIBRARY.read_text(encoding="utf-8")
        cli = RELEASE_GATE_CLI.read_text(encoding="utf-8")
        tests = RELEASE_GATE_TEST.read_text(encoding="utf-8")

        self.assertNotIn("shell=True", library + cli)
        self.assertEqual(2, library.count("shell=False"))
        self.assertNotIn('"gh api', library + cli)
        self.assertIn('argv = [\n            "gh",\n            "api",', library)
        self.assertRegex(
            library,
            r"self\.runner\(\n\s+argv,\n\s+capture_output=True,\n\s+check=False,\n"
            r"\s+env=child_environment,\n\s+shell=False,",
        )
        self.assertIn('["git", "-C", str(self.workspace), *arguments]', library)
        self.assertIn(
            'f"/repos/{self.repository}/commits/{self.commit}/statuses?per_page=100"',
            library,
        )
        self.assertIn('child_environment["GH_TOKEN"] = self.token', library)
        self.assertNotIn("top-secret", library + cli)
        for evidence in (
            "test_introduction_equality_with_markerless_release_is_deletion",
            "test_markerless_unrelated_release_is_divergent",
            "test_introduction_absent_repeated_or_malformed_fails",
            "test_marker_bearing_feature_commit_before_first_parent_merge_is_applicable",
            "test_exact_argv_slurp_shape_token_isolation_and_shell_false",
            "test_missing_and_pending_timeout_at_fake_1800_second_deadline",
        ):
            self.assertIn(evidence, tests)

    def test_python_qualification_hardening_is_registered(self):
        library = RELEASE_GATE_LIBRARY.read_text(encoding="utf-8")
        cli = RELEASE_GATE_CLI.read_text(encoding="utf-8")
        tests = RELEASE_GATE_TEST.read_text(encoding="utf-8")

        self.assertIn("TARGET_DECLARATION.search(target)", library)
        self.assertIn("ACTION_DECLARATION.search(action)", library)
        self.assertNotIn("TARGET_TEXT not in target", library)
        self.assertNotIn("ACTION_TEXT not in action", library)
        self.assertIn("timeout=timeout_seconds", library)
        self.assertIn("except subprocess.TimeoutExpired", library)
        self.assertIn("math.isfinite", library)
        self.assertIn("math.isfinite", cli)
        for regression in (
            "test_comment_only_and_lookalike_target_declarations_fail_before_status",
            "test_comment_only_and_lookalike_action_declarations_fail_before_status",
            "test_success_returned_after_deadline_is_rejected",
            "test_gh_runner_receives_remaining_monotonic_budget_each_snapshot",
            "test_hung_gh_snapshot_timeout_is_a_policy_error",
            "test_successful_ambiguous_revision_warning_fails_closed",
            "test_url_rejects_raw_whitespace_or_controls_before_parsing",
            "test_nonfinite_timeout_and_poll_are_rejected_with_sanitized_cli_errors",
        ):
            self.assertIn(regression, tests)

    def test_release_permissions_checkout_and_qualifier_are_exact(self):
        self.assertEqual(
            ("contents: write", "id-token: write", "statuses: read"),
            release_permissions(),
        )
        checkout = named_release_step("Checkout")
        self.assertIn("fetch-depth: 0", checkout)
        self.assertEqual(
            self.qualifier_step, named_release_step("Wait for large-ingestion gate")
        )

    def test_qualifier_precedes_tools_metadata_checkout_and_publication(self):
        workflow = RELEASE_WORKFLOW.read_text(encoding="utf-8")
        ordered_steps = (
            "Enforce release source",
            "Cache Bazel artifacts",
            "Configure BuildBuddy remote cache",
            "Install Bazelisk",
            "Wait for large-ingestion gate",
            "Install Cosign",
            "Install ORAS",
            "Resolve release metadata",
            "Checkout release commit",
            "Publish container images",
        )
        positions = [workflow.index(f"      - name: {name}\n") for name in ordered_steps]
        self.assertEqual(sorted(positions), positions)

    def test_qualifier_uses_exact_full_sha_options_without_inline_policy(self):
        step = named_release_step("Wait for large-ingestion gate")
        required = (
            'RELEASE_COMMIT: ${{ steps.source.outputs.commit }}',
            "//build/ci:wait_for_large_ingestion_gate",
            '--repository "${GITHUB_REPOSITORY}"',
            '--commit "${RELEASE_COMMIT}"',
            "--base-ref origin/staging",
            "--token-env GH_TOKEN",
            "--timeout-seconds 1800",
            "--poll-seconds 15",
            "--target-url-prefix https://carverauto.buildbuddy.io/invocation/",
        )
        for value in required:
            self.assertEqual(1, step.count(value), value)
        for forbidden in (
            "git show",
            "git log",
            "merge-base",
            "grep",
            "gh api",
            "jq",
            "HEAD",
            "GITHUB_SHA",
            "GITHUB_REF",
            "steps.release.outputs.commit",
            "steps.source.outputs.tag",
            "HISTORICAL_NOT_APPLICABLE",
            "missing introduction",
            "missing contract",
        ):
            self.assertNotIn(forbidden, step)


if __name__ == "__main__":
    if sys.argv[1:] == ["--hash-integration-benchmark"]:
        print(harness_hash())
    else:
        unittest.main()
