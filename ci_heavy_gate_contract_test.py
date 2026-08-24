"""Static contract for the explicit-only core integration benchmark harness."""

import csv
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
BENCHMARK_CONTRACT = (
    ROOT / "openspec/changes/parallelize-core-integration-tests/benchmark.md"
)
CORE_BUILD = ROOT / "elixir/serviceradar_core/BUILD.bazel"
CORE_TEST_ROOT = ROOT / "elixir/serviceradar_core/test"
INTEGRATION_DISPOSITIONS = CORE_TEST_ROOT / "INTEGRATION_SOURCE_DISPOSITIONS.tsv"
INTEGRATION_SHARDS = ROOT / "build/integration_shards.bzl"
INTEGRATION_DISPOSITIONS_BZL = ROOT / "build/integration_test_dispositions.bzl"
RELEASE_WORKFLOW = ROOT / ".github/workflows/release.yml"
RELEASE_GATE_MARKER = ROOT / "build/ci/large_ingestion_gate_contract.v1"
RELEASE_GATE_BUILD = ROOT / "build/ci/BUILD.bazel"
RELEASE_GATE_LIBRARY = ROOT / "build/ci/large_ingestion_gate.py"
RELEASE_GATE_CLI = ROOT / "build/ci/wait_for_large_ingestion_gate.py"
RELEASE_GATE_TEST = ROOT / "build/ci/wait_for_large_ingestion_gate_test.py"
TEST_HELPER = ROOT / "elixir/serviceradar_core/test/test_helper.exs"
TEST_SUPPORT = ROOT / "elixir/serviceradar_core/test/support/test_support.ex"
INTEGRATION_ENV = ROOT / "elixir/serviceradar_core/test/db/integration_env.exs"
INTEGRATION_ENV_CONFIG = (
    ROOT / "elixir/serviceradar_core/test/db/integration_env_config.exs"
)
TEST_DATABASE_GUARD = (
    ROOT / "elixir/serviceradar_core/config/test_database_guard.exs"
)
CORE_TEST_CONFIG = ROOT / "elixir/serviceradar_core/config/test.exs"
CI_ENVIRONMENT = ROOT / "config/environments/ci.textproto"
SRQL_INTEGRATION_BUILD = ROOT / "integration_tests/srql/BUILD.bazel"
SRQL_INTEGRATION_HARNESS = ROOT / "integration_tests/srql/tests/support/harness.rs"
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
SERIAL_COMPOSITE_CHECK_SRCS = (
    "test/serviceradar/composite_checks/composite_check_test.exs",
    "test/serviceradar/composite_checks/composite_check_rule_test.exs",
    "test/serviceradar/composite_checks/composite_check_input_test.exs",
    "test/serviceradar/composite_checks/device_composite_check_result_test.exs",
)
DATABASE_BOOTSTRAP_SOURCE = (
    "test/serviceradar/cluster/database_bootstrap_integration_test.exs"
)
DATABASE_BOOTSTRAP_TEST = ROOT / "elixir/serviceradar_core" / DATABASE_BOOTSTRAP_SOURCE
STARTUP_MIGRATIONS = (
    ROOT
    / "elixir/serviceradar_core/lib/serviceradar/cluster/startup_migrations.ex"
)

DISPOSITION_FIELDS = (
    "source",
    "module",
    "case_kind",
    "mode",
    "reason",
    "evidence",
)
SELECTED_CASE_KINDS = {"data_case", "non_data_case"}
SELECTED_MODES = {"async", "serial"}
SERIAL_REASONS = {
    "application_env",
    "ddl",
    "fixed_external",
    "global_cache",
    "global_process",
    "global_pubsub",
    "global_registry",
    "global_telemetry",
    "materialized_view",
    "multi_connection",
    "oban_global",
    "truncate",
    "unboxed",
    "unmanaged_child",
    "vm_global",
}


def fixed_external_resource_sources() -> tuple[str, ...]:
    source = INTEGRATION_DISPOSITIONS_BZL.read_text(encoding="utf-8")
    match = re.search(
        r"FIXED_EXTERNAL_INTEGRATION_SRCS = \[\n(?P<sources>.*?)\n\]",
        source,
        re.DOTALL,
    )
    if not match:
        raise AssertionError("FIXED_EXTERNAL_INTEGRATION_SRCS is missing")
    return tuple(re.findall(r'^    "([^"]+)",$', match.group("sources"), re.MULTILINE))


def projected_integration_sources(name: str) -> tuple[str, ...]:
    source = INTEGRATION_DISPOSITIONS_BZL.read_text(encoding="utf-8")
    match = re.search(
        rf"{re.escape(name)} = \[\n(?P<sources>.*?)\n\]",
        source,
        re.DOTALL,
    )
    if not match:
        raise AssertionError(f"{name} is missing")
    return tuple(re.findall(r'^    "([^"]+)",$', match.group("sources"), re.MULTILINE))


def projected_serial_module_counts() -> dict[str, int]:
    source = INTEGRATION_DISPOSITIONS_BZL.read_text(encoding="utf-8")
    match = re.search(
        r"SERIAL_INTEGRATION_MODULE_COUNTS = \{\n(?P<entries>.*?)\n\}",
        source,
        re.DOTALL,
    )
    if not match:
        raise AssertionError("SERIAL_INTEGRATION_MODULE_COUNTS is missing")
    return {
        path: int(count)
        for path, count in re.findall(
            r'^    "([^"]+)": ([0-9]+),$', match.group("entries"), re.MULTILINE
        )
    }


def ordinary_core_test_sources() -> tuple[str, ...]:
    excluded_sources = {
        DATABASE_BOOTSTRAP_SOURCE,
        "test/serviceradar/edge/agent_command_bus_rpc_registry_test.exs",
    }
    sources = []

    for path in CORE_TEST_ROOT.rglob("*_test.exs"):
        source = path.relative_to(CORE_TEST_ROOT.parent).as_posix()
        if source.startswith("test/db/") or source.startswith("test/release_gates/"):
            continue
        if source in excluded_sources:
            continue
        sources.append(source)

    return tuple(sorted(sources))


def integration_dispositions() -> tuple[dict[str, str], ...]:
    with INTEGRATION_DISPOSITIONS.open(encoding="utf-8", newline="") as stream:
        reader = csv.DictReader(stream, delimiter="\t")
        if tuple(reader.fieldnames or ()) != DISPOSITION_FIELDS:
            raise AssertionError(
                f"unexpected disposition fields: {reader.fieldnames!r}; "
                f"expected {DISPOSITION_FIELDS!r}"
            )
        return tuple(reader)


def module_source_block(source: str, module: str) -> str:
    text = (CORE_TEST_ROOT.parent / source).read_text(encoding="utf-8")
    declaration = re.search(
        rf"(?m)^defmodule\s+{re.escape(module)}\s+do\s*$", text
    )
    if not declaration:
        raise AssertionError(f"{source} does not declare {module}")
    next_module = re.search(r"(?m)^defmodule\s+", text[declaration.end() :])
    end = declaration.end() + next_module.start() if next_module else len(text)
    return text[declaration.start() : end]


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
            "--strategy=TestRunner=local",
            "integration_test,-large_ingestion_test,-acceptance_test",
            "//rust/integration-db:observe_connections",
            "--max-seconds 1800",
            "--required-pool-slots 114",
            "od -An -tx1 -N4 /dev/urandom",
            "//:buildbuddy_setup_fixture_env",
            "//rust/integration-db:teardown_db",
        ):
            self.assertIn(required, self.action)

        # ExUnit's built-in slowest report implicitly enables trace, which forces
        # max_cases=1 and disables test timeouts. Authoritative benchmark runs must
        # exercise the checked-in integration concurrency cap instead.
        self.assertNotIn("SERVICERADAR_TEST_SLOWEST", self.action)

    def test_benchmark_uses_the_checked_in_async_cap(self):
        shards = INTEGRATION_SHARDS.read_text(encoding="utf-8")
        cap_match = re.search(
            r"^INTEGRATION_ASYNC_MAX_CASES = (\d+)$", shards, re.MULTILINE
        )
        self.assertIsNotNone(cap_match)
        cap = cap_match.group(1)

        benchmark = BENCHMARK_CONTRACT.read_text(encoding="utf-8")
        self.assertIn(
            f"final broad-async implementation commit at `max_cases: {cap}`",
            benchmark,
        )
        self.assertIn(
            f"after revision must report\n`max_cases: {cap}`",
            benchmark,
        )

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

    def test_database_flags_disable_cache_and_remote_upload(self):
        preflight_start = self.action.index('PREFLIGHT_FLAGS="')
        preflight_end = self.action.index('preflight="$(bazel', preflight_start)
        measured_start = self.action.index('\n          FLAGS="-c opt --config=ci')
        measured_end = self.action.index("OBSERVER_DIR=", measured_start)

        for phase, block in (
            ("preflight", self.action[preflight_start:preflight_end]),
            ("measured", self.action[measured_start:measured_end]),
        ):
            with self.subTest(phase=phase):
                self.assertEqual(1, block.count("--nocache_test_results"))
                self.assertEqual(1, block.count("--noremote_upload_local_results"))

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
    def observer_start(self, required_pool_slots: int) -> str:
        return (
            "bazel run -c opt --config=ci --//build:enable_integration_tests "
            "--//build:run_id=$RUN_ID //rust/integration-db:observe_connections -- "
            '--ready-file "$READY_FILE" --suite-complete-file "$SUITE_COMPLETE_FILE" '
            '--quiescent-file "$QUIESCENT_FILE" --stop-file "$STOP_FILE" '
            f"--max-seconds 1800 --required-pool-slots {required_pool_slots} &"
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
        required_pool_slots: int,
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
            self.observer_start(required_pool_slots),
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

    def test_database_flags_disable_cache_and_remote_upload(self):
        for action_name in ("BazelCI", "LargeIngestionGate"):
            with self.subTest(action=action_name):
                self.assert_cache_flags(action_name)

    def test_guarded_elixir_suites_cannot_bypass_the_typed_ci_fixture(self):
        preload = INTEGRATION_ENV.read_text(encoding="utf-8")
        resolver = INTEGRATION_ENV_CONFIG.read_text(encoding="utf-8")
        core_build = CORE_BUILD.read_text(encoding="utf-8")
        ci_environment = CI_ENVIRONMENT.read_text(encoding="utf-8")

        self.assertIn("ServiceRadar.DB.IntegrationEnvConfig.configure!(", preload)
        self.assertNotIn('System.get_env("SRQL_TEST_DATABASE_URL")', preload)
        self.assertNotIn(
            'System.get_env("SERVICERADAR_TEST_DATABASE_URL")', preload
        )
        self.assertIn("fixture_resolver \\\\ &FixtureConfig.resolve!/1", resolver)
        self.assertIn("System.put_env(@database_url_env, url)", resolver)
        self.assertIn('"//config/environments:ci_binpb"', core_build)
        self.assertIn('"//config/manager_config/elixir:manager"', core_build)
        self.assertIn('"//config/manager_secret/elixir:secret"', core_build)
        self.assertIn(
            'host: "srql-fixture-rw.srql-fixtures.svc.cluster.local"',
            ci_environment,
        )
        self.assertIn('database: "srql_fixture"', ci_environment)

    def test_every_direct_database_backed_mix_run_is_confined_to_srql_fixtures(self):
        guard = TEST_DATABASE_GUARD.read_text(encoding="utf-8")
        test_config = CORE_TEST_CONFIG.read_text(encoding="utf-8")

        self.assertIn(
            '@fixture_tls_name "srql-fixture-rw.srql-fixtures.svc.cluster.local"',
            guard,
        )
        self.assertIn("sr_core_test_", guard)
        self.assertIn("codex_", guard)
        self.assertIn('ssl_mode != "verify-full"', guard)
        self.assertIn("not ca_configured?", guard)
        self.assertIn("validate_query!(uri.query)", guard)
        self.assertIn("fixture_dial_target?", guard)
        self.assertIn('Code.require_file("test_database_guard.exs", __DIR__)', test_config)
        self.assertIn("alias ServiceRadar.DB.TestDatabaseGuard", test_config)
        self.assertIn("TestDatabaseGuard.validate!", test_config)
        self.assertNotIn("SERVICERADAR_TEST_DATABASE_TEMPLATE_LIFECYCLE", test_config)

    def test_guarded_bazel_database_targets_stage_only_the_ci_fixture_identity(self):
        core_build = CORE_BUILD.read_text(encoding="utf-8")
        integration_db_build = OBSERVER_BUILD.read_text(encoding="utf-8")
        srql_build = SRQL_INTEGRATION_BUILD.read_text(encoding="utf-8")

        for source in (core_build, integration_db_build, srql_build):
            self.assertIn("//config/environments:ci_binpb", source)
            self.assertNotIn("//config/environments:localhost_binpb", source)

    def test_cold_bootstrap_scratch_cleanup_is_outcome_bearing(self):
        source = DATABASE_BOOTSTRAP_TEST.read_text(encoding="utf-8")
        self.assertIn(
            "on_exit(fn ->\n      drop_database!(admin_opts, scratch_db)\n    end)",
            source,
        )
        self.assertIn("defp drop_database!(admin_opts, database) do", source)
        self.assertIn('raise "failed to drop bootstrap scratch database', source)
        self.assertNotIn("sweep_stale_dbs will collect it", source)

    def test_cold_bootstrap_admin_ddl_uses_the_typed_fixture_endpoint(self):
        source = DATABASE_BOOTSTRAP_TEST.read_text(encoding="utf-8")
        self.assertIn('FixtureConfig.admin_url!("postgres")', source)
        self.assertNotIn(
            'System.get_env("SERVICERADAR_TEST_ADMIN_URL")', source
        )
        self.assertNotIn('System.get_env("SRQL_TEST_ADMIN_URL")', source)

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
        required_pool_slots: int,
    ) -> None:
        for required in (
            'SRQL_FIXTURE_CA_URL: "http://srql-fixture-ca-incluster.srql-fixtures.svc.cluster.local/ca.crt"',
            "export BAZEL_PROFILE=ci",
            "export SERVICERADAR_ENV=ci",
            "--strategy=TestRunner=local",
            "--//build:enable_integration_tests",
            "--//build:run_id=$RUN_ID",
            "--flaky_test_attempts=1",
            "--test_output=all",
            "od -An -tx1 -N4 /dev/urandom",
            "export RUN_ID",
            "//:buildbuddy_setup_fixture_env",
            "//rust/integration-db:observe_connections",
            '--ready-file "$READY_FILE"',
            '--suite-complete-file "$SUITE_COMPLETE_FILE"',
            '--quiescent-file "$QUIESCENT_FILE"',
            '--stop-file "$STOP_FILE"',
            "--max-seconds 1800",
            f"--required-pool-slots {required_pool_slots}",
            provision_command,
            suite_command,
        ):
            self.assertIn(required, action)

        environment_bindings = re.findall(
            r"\bSERVICERADAR_ENV=([A-Za-z0-9_-]+)", action
        )
        self.assertTrue(environment_bindings)
        self.assertEqual({"ci"}, set(environment_bindings))

        self.assertNotIn("SERVICERADAR_TEST_SLOWEST", action)

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
            114,
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
            114,
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
            15,
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
            15,
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

    def test_integration_disposition_inventory_is_exhaustive_and_concrete(self):
        rows = integration_dispositions()
        selected = [row for row in rows if row["mode"] in SELECTED_MODES]
        load_only = [row for row in rows if row["mode"] == "load_only"]

        self.assertEqual(278, len(selected))
        self.assertEqual(500, len(load_only))
        self.assertEqual(778, len(rows))
        self.assertEqual(
            set(ordinary_core_test_sources()),
            {row["source"] for row in rows},
        )

        keys = [(row["source"], row["module"]) for row in rows]
        self.assertEqual(len(keys), len(set(keys)), "duplicate disposition key")

        modes_by_source: dict[str, set[str]] = {}
        for row in rows:
            source = row["source"]
            modes_by_source.setdefault(source, set()).add(row["mode"])
            self.assertTrue(row["evidence"].strip(), row)
            self.assertNotEqual(row["reason"], row["evidence"].strip(), row)
            self.assertFalse(
                {"pending", "legacy", "unknown"}
                & {value.strip().lower() for value in row.values()},
                row,
            )

            if row["mode"] == "load_only":
                self.assertEqual("-", row["module"], row)
                self.assertEqual("not_selected", row["case_kind"], row)
                self.assertEqual("not_selected", row["reason"], row)
                continue

            self.assertIn(row["case_kind"], SELECTED_CASE_KINDS, row)
            self.assertIn(row["mode"], SELECTED_MODES, row)
            if row["mode"] == "async":
                self.assertEqual(
                    "transaction_owner"
                    if row["case_kind"] == "data_case"
                    else "explicit_async",
                    row["reason"],
                    row,
                )
            else:
                self.assertIn(row["reason"], SERIAL_REASONS, row)

        for source, modes in modes_by_source.items():
            selected_modes = modes & SELECTED_MODES
            self.assertLessEqual(len(selected_modes), 1, (source, modes))
            self.assertFalse(
                "load_only" in modes and selected_modes,
                (source, modes),
            )

    def test_selected_module_declarations_match_the_disposition_inventory(self):
        for row in integration_dispositions():
            if row["mode"] == "load_only":
                continue

            block = module_source_block(row["source"], row["module"])
            declarations = re.findall(
                r"(?m)^\s*use\s+(ServiceRadar\.DataCase|ExUnit\.Case),\s*async:\s*(true|false)\s*$",
                block,
            )
            indirect_data_case = re.findall(
                r"(?m)^\s*use\s+ServiceRadar\.Observability\.PluginResultIngestorTestSupport\s*$",
                block,
            )
            self.assertEqual(1, len(declarations) + len(indirect_data_case), row)

            if indirect_data_case:
                case_template, async_value = "ServiceRadar.DataCase", "false"
            else:
                case_template, async_value = declarations[0]

            self.assertEqual(
                "ServiceRadar.DataCase"
                if row["case_kind"] == "data_case"
                else "ExUnit.Case",
                case_template,
                row,
            )
            self.assertEqual(
                "true" if row["mode"] == "async" else "false",
                async_value,
                row,
            )

    def test_fixed_external_dispositions_are_confined_to_serial_zero_inputs(self):
        rows = integration_dispositions()
        fixed_rows = [row for row in rows if row["reason"] == "fixed_external"]

        self.assertEqual(
            set(FIXED_EXTERNAL_RESOURCE_PATHS),
            {row["source"] for row in fixed_rows},
        )
        for row in fixed_rows:
            self.assertEqual("serial", row["mode"], row)
            self.assertEqual("data_case", row["case_kind"], row)

    def test_starlark_lane_projection_exactly_matches_the_inventory(self):
        rows = integration_dispositions()
        async_sources = tuple(
            sorted({row["source"] for row in rows if row["mode"] == "async"})
        )
        serial_counts: dict[str, int] = {}
        for row in rows:
            if row["mode"] == "serial":
                serial_counts[row["source"]] = serial_counts.get(row["source"], 0) + 1

        self.assertEqual(
            async_sources,
            projected_integration_sources("ASYNC_INTEGRATION_SRCS"),
        )
        self.assertEqual(serial_counts, projected_serial_module_counts())
        self.assertEqual(
            FIXED_EXTERNAL_RESOURCE_PATHS,
            projected_integration_sources("FIXED_EXTERNAL_INTEGRATION_SRCS"),
        )
        self.assertTrue(set(async_sources).isdisjoint(serial_counts))
        self.assertTrue(
            set(FIXED_EXTERNAL_RESOURCE_PATHS).issubset(serial_counts)
        )

    def test_composite_check_sources_remain_serial_data_cases(self):
        async_sources = set(
            projected_integration_sources("ASYNC_INTEGRATION_SRCS")
        )
        self.assertTrue(set(SERIAL_COMPOSITE_CHECK_SRCS).isdisjoint(async_sources))
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
        unit_tests = core_build[
            core_build.index('name = "unit_tests"') : core_build.index(
                '[\n    ex_unit_test(\n        name = "integration_tests_{}"'
            )
        ]

        self.assertIn("srcs = INTEGRATION_LANE_SRCS[lane]", generated_targets)
        self.assertIn("env = integration_test_env(lane)", generated_targets)
        self.assertIn("for lane in integration_lane_names()", generated_targets)
        self.assertNotIn("srcs = ALL_TEST_SRCS", generated_targets)
        self.assertNotIn("SERVICERADAR_INTEGRATION_MAX_CASES", unit_tests)

    def test_obsolete_topology_challenger_is_absent(self):
        core_build = CORE_BUILD.read_text(encoding="utf-8")
        shard_build = INTEGRATION_SHARDS.read_text(encoding="utf-8")

        self.assertNotIn("integration_tests_topology_1", core_build)
        self.assertNotIn("one_beam_integration_test_env", shard_build)
        self.assertNotIn("INTEGRATION_MAX_CASES = 2", shard_build)
        self.assertIn("INTEGRATION_ASYNC_MAX_CASES = 8", shard_build)
        self.assertIn("INTEGRATION_SERIAL_MAX_CASES = 1", shard_build)
        self.assertIn("INTEGRATION_REPO_POOL_SIZE = 12", shard_build)
        self.assertIn("INTEGRATION_MAX_BEAMS = 8", shard_build)
        self.assertIn("INTEGRATION_MAX_POOL_SLOTS = 96", shard_build)
        self.assertIn("INTEGRATION_AUXILIARY_CONNECTION_SLOTS = 18", shard_build)
        self.assertIn("INTEGRATION_WORKFLOW_CONNECTION_SLOTS = 114", shard_build)

    def test_workflow_capacity_includes_the_three_selected_srql_harnesses(self):
        srql_build = SRQL_INTEGRATION_BUILD.read_text(encoding="utf-8")
        harness = SRQL_INTEGRATION_HARNESS.read_text(encoding="utf-8")

        self.assertEqual(3, srql_build.count('tags = ["integration_test"]'))
        self.assertIn("max_pool_size: 5", harness)
        self.assertIn("RemoteFixtureGuard::acquire", harness)
        self.assertIn(
            "INTEGRATION_AUXILIARY_CONNECTION_SLOTS = 18",
            INTEGRATION_SHARDS.read_text(encoding="utf-8"),
        )

    def test_integration_cap_is_parsed_before_starting_ex_unit(self):
        source = TEST_HELPER.read_text(encoding="utf-8")
        selection = 'if System.get_env("SERVICERADAR_ONLY_INTEGRATION") in ["1", "true", "TRUE"] do'
        branch = integration_only_branch()
        outside_branch = source[: source.index(selection)] + source[source.index(branch) + len(branch) :]

        topology_read = branch.index(
            'System.get_env("SERVICERADAR_TEST_TOPOLOGY", "focused")'
        )
        lane_read = branch.index(
            'System.get_env("SERVICERADAR_TEST_LANE", "focused")'
        )
        parser_assignment = branch.index("integration_max_cases =")
        parser_call = branch.index("ServiceRadar.TestSupport.integration_max_cases!", parser_assignment)
        environment_read = branch.index(
            'System.get_env("SERVICERADAR_INTEGRATION_MAX_CASES")', parser_call
        )
        formatter_env = branch.index(
            'System.get_env("SERVICERADAR_INTEGRATION_SELECTION_OUTPUT")',
            environment_read,
        )
        formatter_config = branch.index(
            "ServiceRadar.IntegrationSelectionFormatter",
            formatter_env,
        )
        self.assertIn("formatters:", branch[formatter_env:formatter_config])
        self.assertIn("ExUnit.CLIFormatter", branch[formatter_env:formatter_config])
        repo_pool_read = branch.index(
            "Keyword.fetch!(:pool_size)", formatter_config
        )
        repo_pool_validation = branch.index(
            "ServiceRadar.TestSupport.integration_repo_pool_size!", repo_pool_read
        )
        runner_marker = branch.index(
            '"SERVICERADAR_INTEGRATION_RUNNER topology=#{topology} lane=#{lane} '
            'max_cases=#{integration_max_cases} schedulers=#{System.schedulers_online()} '
            'repo_pool=#{repo_pool} trace=false timeouts=enabled"',
            repo_pool_validation,
        )
        profiling_marker = branch.index(
            '"SERVICERADAR_INTEGRATION_RUNNER topology=#{topology} lane=#{lane} max_cases=1 '
            'schedulers=#{System.schedulers_online()} repo_pool=#{repo_pool} trace=true '
            'timeouts=infinity profiling_only=true"',
            repo_pool_validation,
        )
        ex_unit_start = branch.index("ExUnit.start(", environment_read)
        max_cases_option = branch.index("max_cases: integration_max_cases", ex_unit_start)
        parser_arguments = branch[parser_call:formatter_env]

        self.assertLess(branch.index(selection), parser_assignment)
        self.assertLess(topology_read, parser_assignment)
        self.assertLess(lane_read, parser_assignment)
        self.assertLess(parser_assignment, parser_call)
        self.assertLess(parser_call, environment_read)
        self.assertLess(environment_read, formatter_env)
        self.assertLess(formatter_env, formatter_config)
        self.assertLess(formatter_config, repo_pool_read)
        self.assertLess(repo_pool_read, repo_pool_validation)
        self.assertLess(repo_pool_validation, runner_marker)
        self.assertLess(runner_marker, profiling_marker)
        self.assertLess(profiling_marker, ex_unit_start)
        self.assertLess(ex_unit_start, max_cases_option)
        self.assertIn("topology,", parser_arguments)
        self.assertIn("lane,", parser_arguments)
        self.assertIn("slowest != []", parser_arguments)
        self.assertNotIn("integration_max_cases!", outside_branch)
        self.assertNotIn("max_cases: integration_max_cases", outside_branch)

        support = TEST_SUPPORT.read_text(encoding="utf-8")
        self.assertIn('{{"async_serial", "async"}, 8}', support)
        self.assertIn('{{"large_ingestion", "large_ingestion"}, 1}', support)
        self.assertIn('{{"focused", "focused"}, 1}', support)
        self.assertIn('{{"async_serial", "serial_#{index}"}, 1}', support)
        self.assertIn("@integration_runner_pool_sizes", support)
        self.assertIn("SERVICERADAR_TEST_SLOWEST cannot be combined", support)
        self.assertIn("unsupported integration runner configuration", support)
        self.assertIn("unsupported integration Repo pool configuration", support)
        self.assertNotIn("def integration_max_cases!(value) do", support)

    def test_repeated_core_startup_does_not_implicitly_mutate_audit_configuration(self):
        support = TEST_SUPPORT.read_text(encoding="utf-8")
        helper = TEST_HELPER.read_text(encoding="utf-8")

        self.assertEqual(
            1,
            support.count(
                "if Keyword.has_key?(opts, :synchronous_audit_writes?) do"
            ),
        )
        self.assertIn(
            "not Keyword.fetch!(opts, :synchronous_audit_writes?)", support
        )
        self.assertNotIn(
            "Keyword.get(opts, :synchronous_audit_writes?", support
        )
        self.assertEqual(1, helper.count("synchronous_audit_writes?: true"))

    def test_large_ingestion_gate_has_dedicated_sources_and_database(self):
        core_build = CORE_BUILD.read_text(encoding="utf-8")
        integration_db_build = OBSERVER_BUILD.read_text(encoding="utf-8")
        shard_build = INTEGRATION_SHARDS.read_text(encoding="utf-8")
        ordinary_router = ORDINARY_RESULTS_ROUTER.read_text(encoding="utf-8")
        release_router = RELEASE_RESULTS_ROUTER.read_text(encoding="utf-8")
        release_cardinality = RELEASE_IDENTIFIER_CARDINALITY.read_text(encoding="utf-8")
        all_test_sources = core_build[
            core_build.index("ALL_TEST_SRCS =") : core_build.index(
                "INTEGRATION_LANE_SRCS ="
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
        for release_gate_source in (
            "test/release_gates/large_ingestion/results_router_release_gate_test.exs",
            "test/release_gates/large_ingestion/identifier_cardinality_release_gate_test.exs",
        ):
            self.assertNotIn(release_gate_source, shard_build)

        # Cold bootstrap is production-startup qualification, not ordinary PR-shard work: one
        # quiet serial run already exceeds the complete 90-second PR lifecycle budget. Keep the
        # full two-pass test intact, but make its source membership structurally exclusive.
        self.assertIn(f'"{DATABASE_BOOTSTRAP_SOURCE}"', all_test_sources)
        self.assertNotIn(DATABASE_BOOTSTRAP_SOURCE, shard_build)
        self.assertEqual(2, core_build.count(f'"{DATABASE_BOOTSTRAP_SOURCE}"'))

        self.assertIn('"test/release_gates/**"', all_test_sources)
        self.assertIn('"test/release_gates/**"', runtime_data)
        self.assertIn('"test/**/*_test.exs"', runtime_data)
        self.assertEqual(
            1, generated_targets.count("data = INTEGRATION_RUNTIME_DATA")
        )

        self.assertEqual(1, core_build.count('name = "large_ingestion_release_gate"'))
        self.assertIn('size = "enormous"', release_target)
        self.assertIn('"test/release_gates/large_ingestion/*_test.exs"', release_target)
        self.assertEqual(1, release_target.count(f'"{DATABASE_BOOTSTRAP_SOURCE}"'))
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
            '"SERVICERADAR_TEST_TOPOLOGY": "large_ingestion"', release_target
        )
        self.assertIn(
            '"SERVICERADAR_TEST_LANE": "large_ingestion"', release_target
        )
        self.assertIn(
            '"SERVICERADAR_TEST_DATABASE_POOL_SIZE": str(LARGE_INGESTION_REPO_POOL_SIZE)',
            release_target,
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

        bootstrap = DATABASE_BOOTSTRAP_TEST.read_text(encoding="utf-8")
        self.assertEqual(1, bootstrap.count("|> Keyword.put(:pool_size, 2)"))
        self.assertEqual(
            1,
            bootstrap.count('{"SERVICERADAR_TEST_DATABASE_POOL_SIZE", "2"}'),
        )
        startup_migrations = STARTUP_MIGRATIONS.read_text(encoding="utf-8")
        self.assertEqual(1, startup_migrations.count("case Postgrex.start_link(opts) do"))

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
            '"SERVICERADAR_TEST_DB_SHARDS": ",".join(integration_lane_names())',
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

        self.assertIn("has_large_ingestion_target(target)", library)
        self.assertIn("has_large_ingestion_action(action)", library)
        self.assertIn("tokenize.tokenize", library)
        self.assertNotIn("TARGET_DECLARATION", library)
        self.assertNotIn("ACTION_DECLARATION", library)
        self.assertNotIn(".search(target)", library)
        self.assertNotIn(".search(action)", library)
        self.assertNotIn("TARGET_TEXT not in target", library)
        self.assertNotIn("ACTION_TEXT not in action", library)
        self.assertIn("timeout=timeout_seconds", library)
        self.assertIn("except subprocess.TimeoutExpired", library)
        self.assertIn("math.isfinite", library)
        self.assertIn("math.isfinite", cli)
        for regression in (
            "test_comment_only_and_lookalike_target_declarations_fail_before_status",
            "test_comment_only_and_lookalike_action_declarations_fail_before_status",
            "test_starlark_multiline_string_target_lookalike_fails_before_status",
            "test_yaml_block_scalar_action_lookalike_fails_before_status",
            "test_malformed_target_or_action_source_fails_before_status",
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
