"""Static contract for the explicit-only core integration benchmark harness."""

import csv
import hashlib
import os
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parent
BAZELRC = ROOT / ".bazelrc"
MODULE_FILE = ROOT / "MODULE.bazel"
WORKFLOW = ROOT / "buildbuddy.yaml"
PLAYWRIGHT_BUILD = ROOT / "elixir/web-ng/test/playwright/BUILD.bazel"
PLAYWRIGHT_EXECUTOR_IMAGE = (
    "docker://registry.carverauto.dev/serviceradar/playwright-rbe@sha256:"
    "d9266ee97f0dbd297618a10afb00b5006ebf2bb19dd38887da3230ed4b7829ea"
)
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
INTEGRATION_TESTS_BZL = ROOT / "build/integration_tests.bzl"
RELEASE_WORKFLOW = ROOT / ".github/workflows/release.yml"
RELEASE_GATE_MARKER = ROOT / "build/ci/large_ingestion_gate_contract.v1"
RELEASE_GATE_BUILD = ROOT / "build/ci/BUILD.bazel"
RELEASE_GATE_LIBRARY = ROOT / "build/ci/large_ingestion_gate.py"
RELEASE_GATE_CLI = ROOT / "build/ci/wait_for_large_ingestion_gate.py"
RELEASE_GATE_TEST = ROOT / "build/ci/wait_for_large_ingestion_gate_test.py"
TEST_HELPER = ROOT / "elixir/serviceradar_core/test/test_helper.exs"
TEST_SUPPORT = ROOT / "elixir/serviceradar_core/test/support/test_support.ex"
DATA_CASE = ROOT / "elixir/serviceradar_core/test/support/data_case.ex"
PLATFORM_BASELINE = (
    ROOT / "elixir/serviceradar_core/priv/repo/baseline/platform_schema.sql"
)
INVENTORY_ROLLUP_TRIGGER_SOURCE = (
    "test/serviceradar/inventory/sync_ingestor_vendor_type_test.exs"
)
ASYNC_SANDBOX_CONFIGURATION_SOURCE = (
    "test/serviceradar/async_sandbox_configuration_test.exs"
)
INTEGRATION_ENV = ROOT / "elixir/serviceradar_core/test/db/integration_env.exs"
TEMPLATE_ENV = ROOT / "elixir/serviceradar_core/test/db/template_env.exs"
TEMPLATE_AUTHORITY_BZL = ROOT / "build/template_authority.bzl"
BUILD_FLAGS = ROOT / "build/BUILD.bazel"
INTEGRATION_DB_LIB = ROOT / "rust/integration-db/src/lib.rs"
INTEGRATION_DB_BUILD = ROOT / "rust/integration-db/BUILD.bazel"
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
SRQL_INTEGRATION_ROOT = ROOT / "integration_tests/srql"
INTEGRATION_DB_ROOT = ROOT / "rust/integration-db"
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
ASYNC_ON_EXIT_ALLOWED_SOURCES = {
    "test/serviceradar/integrations/armis_northbound_runner_test.exs",
    "test/serviceradar/inventory/agent_link_repair_worker_test.exs",
    "test/serviceradar/notifications/dispatcher_delivery_test.exs",
}
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
    "shared_global_rows",
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


def literal_run_bodies(action: str) -> list[str]:
    """Every literal (`|`) run block in an action, dedented to a runnable shell."""
    marker = "      - run: |\n"
    bodies = []
    for match in re.finditer(re.escape(marker), action):
        body = []
        for line in action[match.end() :].splitlines(keepends=True):
            if line.strip() == "":
                body.append(line)
            elif line.startswith("          "):
                body.append(line[10:])
            else:
                break
        bodies.append("".join(body))
    return bodies


def sole_literal_run_body(action: str, marker: str, description: str) -> str:
    """The one literal run block containing `marker`."""
    matches = [body for body in literal_run_bodies(action) if marker in body]
    if len(matches) != 1:
        raise AssertionError(f"expected exactly one {description}, found {len(matches)}")
    return matches[0]


def database_lifecycle_shell(action: str) -> str:
    """The measured database lifecycle shell: the `|` block owning cleanup().

    Scoped by content, not by count: the godview acceptance path gate (#4165)
    is also a literal `|` block, so "exactly one" no longer selects the
    lifecycle. Only the lifecycle defines cleanup().
    """
    return sole_literal_run_body(action, "cleanup() {", "database lifecycle shell")


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


def cpu_diagnostic_input_paths() -> tuple[Path, ...]:
    """Return every file whose content can change the CPU diagnostic workload."""
    selected_sources = {
        CORE_TEST_ROOT.parent / row["source"]
        for row in integration_dispositions()
        if row["mode"] in SELECTED_MODES
    }
    fixed_inputs = {
        BAZELRC,
        Path(__file__).resolve(),
        CORE_BUILD,
        CORE_TEST_CONFIG,
        CI_ENVIRONMENT,
        DATA_CASE,
        INTEGRATION_DISPOSITIONS,
        INTEGRATION_DISPOSITIONS_BZL,
        INTEGRATION_ENV,
        INTEGRATION_ENV_CONFIG,
        INTEGRATION_SHARDS,
        INTEGRATION_TESTS_BZL,
        PLATFORM_BASELINE,
        TEST_DATABASE_GUARD,
        TEST_HELPER,
        TEST_SUPPORT,
    }
    lifecycle_inputs = {
        path
        for root in (INTEGRATION_DB_ROOT, SRQL_INTEGRATION_ROOT)
        for path in root.rglob("*")
        if path.is_file()
    }
    return tuple(
        sorted(
            fixed_inputs | selected_sources | lifecycle_inputs,
            key=lambda path: path.relative_to(ROOT).as_posix(),
        )
    )


def normalized_cpu_diagnostic_action(action: str) -> str:
    """Exclude the one post-diagnostic production CPU choice from the base action."""
    cpu_requests = re.findall(r'^      cpu: "([^"]+)"$', action, re.MULTILINE)
    if len(cpu_requests) > 1:
        raise AssertionError("benchmark action has multiple CPU resource requests")
    if cpu_requests and cpu_requests[0] not in {"2", "12"}:
        raise AssertionError(
            f"unsupported benchmark CPU resource request: {cpu_requests[0]}"
        )
    return re.sub(r'^      cpu: "(?:2|12)"\n', "", action, count=1, flags=re.MULTILINE)


def declared_test_output_modes(action: str) -> tuple[str, ...]:
    """Every --test_output mode an action declares, in source order."""
    return tuple(re.findall(r"--test_output=(\S+)", action))


def godview_gate_shell(action: str) -> str:
    """The BazelCI path-gate shell guarding the browser acceptance run."""
    return sole_literal_run_body(action, "godview gate:", "godview acceptance gate")


def run_godview_gate(
    changed: tuple[str, ...],
    *,
    origin_reachable: bool = True,
    remote_tracking_ref: bool = False,
) -> tuple[int, str, tuple[str, ...]]:
    """Execute the real gate shell against a synthetic repository.

    Builds an `origin` holding `staging`, forks a feature commit touching
    `changed`, and runs the gate with a stub `bazel` on PATH. Returns the exit
    status, the gate's output, and the bazel command lines it issued.

    `remote_tracking_ref` defaults to False because the workflow runner clones
    by SHA: refs/remotes/origin/staging is absent until the gate fetches it.
    """
    shell = godview_gate_shell(named_action("BazelCI"))
    with tempfile.TemporaryDirectory() as temp_dir:
        temp = Path(temp_dir)
        env = {
            **os.environ,
            "HOME": str(temp),
            "GIT_CONFIG_GLOBAL": os.devnull,
            "GIT_CONFIG_SYSTEM": os.devnull,
            "GIT_AUTHOR_NAME": "gate probe",
            "GIT_AUTHOR_EMAIL": "gate@example.com",
            "GIT_COMMITTER_NAME": "gate probe",
            "GIT_COMMITTER_EMAIL": "gate@example.com",
        }

        def git(cwd: Path, *args: str) -> None:
            subprocess.run(
                ("git", *args), cwd=cwd, env=env, check=True, capture_output=True
            )

        origin = temp / "origin"
        origin.mkdir()
        git(origin, "init", "--quiet", "--initial-branch=staging")
        (origin / "README.md").write_text("seed\n", encoding="utf-8")
        git(origin, "add", "README.md")
        git(origin, "commit", "--quiet", "-m", "base")

        work = temp / "work"
        git(temp, "clone", "--quiet", str(origin), str(work))
        git(work, "checkout", "--quiet", "-b", "feature")
        for path in changed:
            target = work / path
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text("changed\n", encoding="utf-8")
        git(work, "add", "--all")
        git(work, "commit", "--quiet", "-m", "feature")

        if not remote_tracking_ref:
            git(work, "update-ref", "-d", "refs/remotes/origin/staging")
        if not origin_reachable:
            git(work, "remote", "remove", "origin")

        bin_dir = temp / "bin"
        bin_dir.mkdir()
        invocations = temp / "bazel-invocations"
        stub = bin_dir / "bazel"
        stub.write_text(
            f'#!/usr/bin/env bash\nprintf "%s\\n" "$*" >>"{invocations}"\n',
            encoding="utf-8",
        )
        stub.chmod(0o755)

        result = subprocess.run(
            ["/bin/bash", "-c", shell],
            cwd=work,
            check=False,
            capture_output=True,
            text=True,
            env={**env, "PATH": f"{bin_dir}{os.pathsep}{env['PATH']}"},
        )
        recorded = (
            tuple(invocations.read_text(encoding="utf-8").splitlines())
            if invocations.exists()
            else ()
        )
        return result.returncode, result.stdout + result.stderr, recorded


def with_test_output_mode(action: str, index: int, mode: str) -> str:
    """Rewrite exactly one --test_output site, so a drift can be simulated."""
    sites = list(re.finditer(r"--test_output=\S+", action))
    if index >= len(sites):
        raise AssertionError(f"action declares no --test_output site {index}")
    site = sites[index]
    return f"{action[: site.start()]}--test_output={mode}{action[site.end() :]}"


def assert_test_output_mode(action: str, expected: str) -> None:
    """Pin EVERY --test_output site in an action to one mode.

    `all` prints the log of every test that RUNS, not just the ones that fail.
    Measured on two green BazelCI runs either side of #4119, which restored the
    INFO events these logs ride on: 592 console lines became 17318, of which
    16726 were eight passing integration lanes narrating themselves. `errors`
    keeps the failing test's full ExUnit block -- the output the console exists
    for -- and drops the rest.

    The two lanes that run on pull requests and staging therefore pin `errors`,
    and the branch-only IntegrationBenchmark harness keeps `all`: it never runs
    on a PR, so it contributes none of that noise, and its command block is
    hashed verbatim by //:integration_benchmark_harness_hash. Editing it for
    consistency alone would invalidate published benchmark evidence for a
    console nobody reads. See the mode-drift test below.

    Asserted over EVERY site rather than one, because each action carries the
    mode in several blocks: a change that flips a single block still leaves an
    `assertIn` anchored on another block passing.
    """
    modes = declared_test_output_modes(action)
    if not modes:
        raise AssertionError("action declares no --test_output mode")
    unexpected = sorted(set(modes) - {expected})
    if unexpected:
        raise AssertionError(
            f"expected every site to be --test_output={expected}, found "
            + ", ".join(f"--test_output={mode}" for mode in unexpected)
        )


def cpu_diagnostic_input_hash() -> str:
    """Hash CPU-arm actions plus the complete checked-in measured workload."""
    digest = hashlib.sha256()
    for name in (
        "IntegrationBenchmark",
        "IntegrationBenchmarkCPU2",
        "IntegrationBenchmarkCPU12",
    ):
        digest.update(normalized(f"action:{name}"))
        action = named_action(name)
        if name == "IntegrationBenchmark":
            action = normalized_cpu_diagnostic_action(action)
        digest.update(normalized(action))

    for path in cpu_diagnostic_input_paths():
        relative_path = path.relative_to(ROOT).as_posix()
        digest.update(normalized(f"path:{relative_path}"))
        digest.update(normalized(path.read_text(encoding="utf-8")))

    return digest.hexdigest()


class SchemaTemplateQualificationContractTest(unittest.TestCase):
    def test_recovery_run_id_is_explicit_validated_and_shared_by_all_steps(self):
        action = named_action("SchemaTemplateQualification")
        self.assertIn("triggers: {}", action)
        self.assertIn('pool: "workflows"', action)
        self.assertIn('${SCHEMA_TEMPLATE_QUALIFICATION_RUN_ID:-$(od ', action)
        guard = '[[ "$RUN_ID" =~ ^[a-z0-9]{8,32}$ ]] ||'
        self.assertIn(guard, action)
        self.assertLess(action.index(guard), action.index("//:buildbuddy_setup_fixture_env"))
        self.assertIn("--//build:run_id=$RUN_ID //:buildbuddy_setup_fixture_env", action)
        self.assertIn("--//build:run_id=$RUN_ID --test_env=SERVICERADAR_ENV=ci", action)
        self.assertIn("--strategy=TestRunner=local", action)
        self.assertIn("--noremote_upload_local_results", action)
        self.assertIn("//rust/integration-db:generation_lifecycle_test", action)

    def test_generation_migrator_declares_the_guarded_replay_environment(self):
        replay_env_path = ROOT / "build/schema_template/replay_env.bzl"
        replay_env = replay_env_path.read_text(encoding="utf-8")
        target = named_starlark_rule(
            CORE_BUILD.read_text(encoding="utf-8"),
            "ex_unit_test",
            "migrate_generation",
        )
        manifest = named_starlark_rule(
            (ROOT / "build/schema_template/BUILD.bazel").read_text(encoding="utf-8"),
            "schema_template_manifest",
            "manifest",
        )
        self.assertIn("env = SCHEMA_TEMPLATE_REPLAY_ENV", target)
        self.assertIn('"MIX_ENV": "test"', replay_env)
        self.assertIn('"SERVICERADAR_MIGRATION_ONLY": "true"', replay_env)
        self.assertIn('"replay_env.bzl"', manifest)


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

    def test_cpu_diagnostic_actions_reuse_the_exact_harness_and_pin_one_cpu_size(self):
        self.assertIn("steps: &integration_benchmark_steps", self.action)

        for name, cpu, branch in (
            (
                "IntegrationBenchmarkCPU2",
                "2",
                "benchmark/parallel-core-integration-cpu2",
            ),
            (
                "IntegrationBenchmarkCPU12",
                "12",
                "benchmark/parallel-core-integration-cpu12",
            ),
        ):
            action = named_action(name)
            self.assertIn('pool: "workflows"', action)
            self.assertIn(f'cpu: "{cpu}"', action)
            self.assertIn(f'branches:\n          - "{branch}"', action)
            self.assertIn("steps: *integration_benchmark_steps", action)
            self.assertNotIn("      - run:", action)
            self.assertNotIn("OCI_REGISTRY", action)
            self.assertNotIn("OCI_AUTH_REQUIRED", action)

    def test_cpu_diagnostic_hash_covers_execution_inputs_but_not_production_cpu(self):
        paths = {
            path.relative_to(ROOT).as_posix()
            for path in cpu_diagnostic_input_paths()
        }

        for required in (
            ".bazelrc",
            "build/integration_shards.bzl",
            "build/integration_test_dispositions.bzl",
            "elixir/serviceradar_core/BUILD.bazel",
            "elixir/serviceradar_core/priv/repo/baseline/platform_schema.sql",
            "elixir/serviceradar_core/test/support/test_support.ex",
            "rust/integration-db/src/lib.rs",
            "integration_tests/srql/tests/support/harness.rs",
        ):
            self.assertIn(required, paths)

        selected_sources = {
            row["source"]
            for row in integration_dispositions()
            if row["mode"] in SELECTED_MODES
        }
        self.assertTrue(selected_sources)
        self.assertTrue(
            selected_sources.issubset(
                {
                    path.relative_to(CORE_TEST_ROOT.parent).as_posix()
                    for path in cpu_diagnostic_input_paths()
                    if path.is_relative_to(CORE_TEST_ROOT.parent)
                }
            )
        )

        digest = cpu_diagnostic_input_hash()
        self.assertRegex(digest, r"^[0-9a-f]{64}$")
        self.assertNotEqual(harness_hash(), digest)

        root_build = (ROOT / "BUILD.bazel").read_text(encoding="utf-8")
        hash_rule = named_starlark_rule(
            root_build,
            "py_binary",
            "integration_cpu_diagnostic_input_hash",
        )
        self.assertIn('args = ["--hash-integration-cpu-diagnostic-inputs"]', hash_rule)
        self.assertNotIn("BazelCI", hash_rule)

        with_selected_cpu = self.action.replace(
            '    resource_requests:\n      memory: "50GB"',
            '    resource_requests:\n      cpu: "12"\n      memory: "50GB"',
            1,
        )
        self.assertNotEqual(self.action, with_selected_cpu)
        self.assertEqual(
            normalized_cpu_diagnostic_action(self.action),
            normalized_cpu_diagnostic_action(with_selected_cpu),
        )

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

        # The measured harness keeps --test_output=all. It is branch-only, so it
        # prints nothing on a PR, and its command block is hashed verbatim.
        assert_test_output_mode(self.action, "all")

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

    def test_expected_sha_is_checked_before_any_build(self):
        sha_check = self.action.index("SERVICERADAR_BENCHMARK_EXPECTED_SHA")
        integration_prebuild = self.action.index("bazel build -c opt --config=ci")
        self.assertLess(sha_check, integration_prebuild)
        self.assertNotIn("//:buildbuddy_setup_docker_auth", self.action)
        self.assertNotIn("OCI_REGISTRY", self.action)
        self.assertNotIn("OCI_AUTH_REQUIRED", self.action)

    def test_prebuild_warms_only_the_measured_integration_targets(self):
        build_start = self.action.index("bazel build -c opt --config=ci")
        lifecycle_start = self.action.index("      - run: |", build_start)
        prebuild = self.action[build_start:lifecycle_start]

        self.assertIn("--//build:enable_integration_tests", prebuild)
        self.assertIn(
            "--build_tag_filters=integration_test,-large_ingestion_test,-acceptance_test",
            prebuild,
        )
        self.assertEqual(1, prebuild.count("//..."))

        manual_prebuild_filter = "--build_tag_filters="
        self.assertEqual(2, prebuild.count(manual_prebuild_filter))
        for target in (
            "//rust/integration-db:observe_connections",
            "//rust/integration-db:sweep_stale_dbs",
            "//rust/integration-db:cleanup_generations",
            "//rust/integration-db:prepare_generation",
            "//rust/integration-db:provision_generation",
            "//rust/integration-db:release_generation",
            "//rust/integration-db:teardown_db",
            "//elixir/serviceradar_core:migrate_generation",
        ):
            self.assertEqual(1, prebuild.count(target), target)

        self.assertRegex(
            prebuild,
            r"--build_tag_filters=\s+//rust/integration-db:observe_connections",
        )
        self.assertEqual(2, prebuild.count("bazel build"))

    def test_the_benchmark_never_writes_the_shared_template(self):
        """The measurement branch is still a branch, and shares one fixture with every other.

        Its keyed preflight can publish only the manifest-selected immutable generation; it
        cannot advance sr_core_template. A benchmark cohort therefore cannot change what a
        different checkout clones. The distinction is not theoretical: one branch once left
        seven migrations in the singleton and every branch without them was refused a clone.
        """
        for target in (
            "//rust/integration-db:prepare_template",
            "//rust/integration-db:reset_template",
            "//elixir/serviceradar_core:migrate_template",
        ):
            self.assertNotIn(target, self.action)
        self.assertIn("--//build:run_id=$RUN_ID", self.action)
        self.assertEqual(3, self.action.count("//rust/integration-db:prepare_generation"))
        self.assertEqual(1, self.action.count("//rust/integration-db:provision_generation)"))
        self.assertIn("//elixir/serviceradar_core:migrate_generation", self.action)

    def test_measured_flags_are_defined_before_each_measured_lifecycle_use(self):
        measured_start = self.action.index("\n          RUN_ID=")
        measured = self.action[measured_start:]
        flags = measured.index('FLAGS="-c opt --config=ci')
        self.assertNotIn("PREFLIGHT_FLAGS", measured)
        for use in (
            "bazel test $FLAGS //rust/integration-db:teardown_db",
            "bazel test $FLAGS //rust/integration-db:sweep_stale_dbs",
            "bazel test $FLAGS //elixir/serviceradar_core:migrate_generation",
            "//rust/integration-db:provision_generation)",
            "bazel test $FLAGS --build_tests_only "
            "--build_tag_filters=integration_test,-large_ingestion_test,-acceptance_test "
            "--test_tag_filters=integration_test,-large_ingestion_test,-acceptance_test //...",
        ):
            self.assertIn(use, measured)
            self.assertLess(flags, measured.index(use))

    def test_database_flags_disable_cache_and_remote_upload(self):
        measured_start = self.action.index('\n          FLAGS="-c opt --config=ci')
        measured_end = self.action.index("OBSERVER_DIR=", measured_start)
        block = self.action[measured_start:measured_end]

        # One flag block covers keyed preflight and measured execution for the same run.
        # Credential-bearing local TestRunner results must not enter the remote cache, and
        # cached results must not contaminate a cohort, so both flags stay pinned once.
        self.assertEqual(1, block.count("--nocache_test_results"))
        self.assertEqual(1, block.count("--noremote_upload_local_results"))
        self.assertEqual(1, block.count("--test_output=all"))

    def test_clock_and_observer_markers_cannot_drift(self):
        self.assertIn("mktemp -d", self.action)
        for marker in ("READY_FILE", "SUITE_COMPLETE_FILE", "QUIESCENT_FILE", "STOP_FILE"):
            self.assertRegex(self.action, rf'{marker}="\$OBSERVER_DIR/')
            self.assertIn(f'[ ! -e "${{{marker}}}" ]', self.action)

        # Schema preparation is outside the clock. Only cloning and the suite are measured.
        start_ns = self.action.index('START_NS="$(date +%s%N)"')
        prepare = self.action.index('PREPARE_JSON="$(bazel run')
        ready = self.action.index('READY_JSON="$(bazel run', prepare)
        provision = self.action.index('PROVISION_JSON="$(bazel run', start_ns)
        self.assertLess(prepare, ready)
        self.assertLess(ready, start_ns)
        self.assertLess(start_ns, provision)
        self.assertNotIn("migrate_template", self.action)

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
    # These are retained only for rollback. No active caller may read or write the singleton.
    template_write_targets = (
        "//rust/integration-db:prepare_template",
        "//rust/integration-db:reset_template",
        "//elixir/serviceradar_core:migrate_template",
        "//rust/integration-db:provision_base",
        "//elixir/serviceradar_core:migrate_run",
        "//rust/integration-db:provision_db",
        "//rust/integration-db:provision_db_large_ingestion",
    )
    measured_migrate_command = (
        "bazel test $FLAGS //elixir/serviceradar_core:migrate_generation"
    )
    generation_cleanup = (
        'CLEANUP_JSON="$(bazel run -c opt --config=ci '
        "--//build:enable_integration_tests --//build:run_id=$RUN_ID "
        '//rust/integration-db:cleanup_generations)"'
    )
    generation_prepare = (
        'PREPARE_JSON="$(bazel run -c opt --config=ci '
        "--//build:enable_integration_tests --//build:run_id=$RUN_ID "
        '//rust/integration-db:prepare_generation)"'
    )
    generation_ready = (
        'READY_JSON="$(bazel run -c opt --config=ci '
        "--//build:enable_integration_tests --//build:run_id=$RUN_ID "
        '//rust/integration-db:prepare_generation)"'
    )
    generation_release = (
        'RELEASE_JSON="$(bazel run -c opt --config=ci '
        "--//build:enable_integration_tests --//build:run_id=$RUN_ID "
        '//rust/integration-db:release_generation)"'
    )
    ordinary_suite = (
        "bazel test $FLAGS --build_tests_only "
        "--build_tag_filters=integration_test,-large_ingestion_test,-acceptance_test "
        "--test_tag_filters=integration_test,-large_ingestion_test,-acceptance_test //..."
    )
    web_db_suite = "bazel test $FLAGS //elixir/web-ng:networks_live_db_test"
    playwright_acceptance = (
        "bazel test -c opt --config=ci "
        "//elixir/web-ng/test/playwright:god_view_elk_scene_acceptance "
        "--test_output=errors --nocache_test_results --flaky_test_attempts=1"
    )
    # The same command as a stub `bazel` on PATH records it: argv without argv[0].
    acceptance_invocation = playwright_acceptance.split(" ", 1)[1]
    heavy_provision = (
        'PROVISION_JSON="$(bazel run -c opt --config=ci '
        "--//build:enable_integration_tests --//build:run_id=$RUN_ID "
        '//rust/integration-db:provision_generation_large_ingestion)"'
    )
    ordinary_provision = (
        'PROVISION_JSON="$(bazel run -c opt --config=ci '
        "--//build:enable_integration_tests --//build:run_id=$RUN_ID "
        '//rust/integration-db:provision_generation)"'
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

    def assert_cache_flags(self, action_name: str) -> None:
        action = named_action(action_name)
        shell = database_lifecycle_shell(action)
        measured = measured_database_lifecycle_shell(action)
        measured_flags_start = measured.index('FLAGS="-c opt --config=ci')
        measured_flags_end = measured.index("OBSERVER_DIR=", measured_flags_start)
        flag_blocks = {"measured": measured[measured_flags_start:measured_flags_end]}
        self.assertNotIn("PREFLIGHT_FLAGS", shell)
        unexpected_counts = {
            phase: {
                flag: block.count(flag)
                for flag in (
                    "--nocache_test_results",
                    "--noremote_upload_local_results",
                    "--test_output=errors",
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
        # The measured lifecycle touches this run's own database and nothing shared. A
        # migrate_template here is the original bug: state every branch reads, advanced from a
        # branch checkout.
        for target in self.template_write_targets:
            self.assertNotIn(target, measured)

        expected = (
            self.fixture_setup,
            self.sweep,
            self.generation_cleanup,
            self.generation_prepare,
            self.measured_migrate_command,
            self.generation_ready,
            self.observer_start(required_pool_slots),
            wait,
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
        lines = normalized_shell_lines(shell)
        positions = [
            lines.index(command)
            for command in (
                self.fixture_setup,
                self.sweep,
                self.generation_cleanup,
                self.generation_prepare,
                self.measured_migrate_command,
                self.generation_ready,
            )
        ]
        self.assertEqual(sorted(positions), positions)
        self.assertIn('if [ "$GENERATION_STATUS" = "needs_migration" ]; then', lines)
        self.assertIn('GENERATION_MIGRATOR_STARTED=0', lines)
        self.assertIn('GENERATION_MIGRATOR_STARTED=1', lines)

    def test_no_active_workflow_may_write_the_shared_template(self):
        """The authority mechanism remains for rollback, but no caller may grant it.

        Every active database workflow now uses immutable generations. Retaining a trunk-only
        singleton writer alongside the keyed callers would silently reintroduce two lifecycle
        families and leave the old cache mutating after the cutover.
        """
        flag = "--//build:template_authority=true"

        for action_name in (
            "BazelCI",
            "LargeIngestionGate",
            "IntegrationBenchmark",
            "IntegrationBenchmarkCPU2",
            "IntegrationBenchmarkCPU12",
        ):
            with self.subTest(action=action_name):
                action = named_action(action_name)
                self.assertNotIn(flag, action)
                for target in self.template_write_targets:
                    self.assertNotIn(target, action)

    def test_the_authority_flag_is_declared_off_and_read_from_the_build_graph(self):
        """A refusal only holds if both halves of the lifecycle can see the same answer.

        The trunk lifecycle writes the template from two languages: //rust/integration-db
        creates and resets it, and //elixir/serviceradar_core:migrate_template performs the
        ratchet. Both read the SAME staged file rather than ambient environment -- the run-id
        format already taught this repository what happens when two steps of one lifecycle
        resolve the same fact independently.
        """
        rust = INTEGRATION_DB_LIB.read_text(encoding="utf-8")
        elixir = TEMPLATE_ENV.read_text(encoding="utf-8")
        starlark = TEMPLATE_AUTHORITY_BZL.read_text(encoding="utf-8")

        # The marker, in all three producers and consumers of it.
        self.assertIn('const TEMPLATE_AUTHORITY_MARKER: &str = "trunk";', rust)
        self.assertIn('_AUTHORITY_MARKER = "trunk"', starlark)
        self.assertIn('String.trim(File.read!(authority_path)) == "trunk"', elixir)

        # The flag defaults to OFF. A default of True would hand write access to every wildcard
        # build, every pull request and every workstation at once, which is strictly worse than
        # the state this replaced.
        build_flags = BUILD_FLAGS.read_text(encoding="utf-8")
        declaration = build_flags[build_flags.index('name = "template_authority"') :]
        self.assertIn(
            "build_setting_default = False", declaration[: declaration.index(")")]
        )

        # Both sides read the staged file, not the environment. A System.get_env of the flag
        # here would be a name the build graph never declared.
        staged = "build/template_authority_file.txt"
        self.assertIn(staged, rust)
        self.assertIn(staged, elixir)

        # And it is actually staged for all three write targets, or the refusal fires on the
        # trunk lifecycle itself: `require_template_authority` fails closed on a missing
        # runfile, so an undeclared input and a withheld grant are the same answer.
        core_build = CORE_BUILD.read_text(encoding="utf-8")
        migrate = core_build[core_build.index('name = "migrate_template"') :]
        migrate = migrate[: migrate.index("\n)\n")]
        self.assertIn('"//build:template_authority_file"', migrate)

        db_build = INTEGRATION_DB_BUILD.read_text(encoding="utf-8")
        self.assertIn(
            'TEMPLATE_WRITE_DATA = ["//build:template_authority_file"]', db_build
        )
        for target in ("prepare_template", "reset_template"):
            with self.subTest(target=target):
                block = db_build[db_build.index(f'name = "{target}"') :]
                block = block[: block.index("\n)\n")]
                self.assertIn("TEMPLATE_WRITE_DATA", block)

        # provision_base must NOT declare it: the run-base path is what every branch uses, and
        # a branch holding shared-template write authority is the bug this file exists to stop.
        base = db_build[db_build.index('name = "provision_base"') :]
        base = base[: base.index("\n)\n")]
        self.assertNotIn("TEMPLATE_WRITE_DATA", base)

    def test_database_flags_disable_cache_and_remote_upload(self):
        for action_name in ("BazelCI", "LargeIngestionGate"):
            with self.subTest(action=action_name):
                self.assert_cache_flags(action_name)

    def test_generation_json_uses_the_declared_runner_python_not_jq(self):
        """The minimal workflow image guarantees Python 3 but does not install jq."""
        for action_name in (
            "BazelCI",
            "LargeIngestionGate",
            "IntegrationBenchmark",
        ):
            with self.subTest(action=action_name):
                shell = named_action(action_name)
                self.assertNotIn("jq", shell)
                for helper in (
                    "validate_cleanup_json()",
                    "parse_prepare_json()",
                    "validate_ready_json()",
                    "validate_lifecycle_json()",
                ):
                    self.assertEqual(1, shell.count(helper), helper)
                self.assertGreaterEqual(shell.count("python3 -c"), 4)
                self.assertIn(
                    "IFS=$'\\t' read -r GENERATION_STATUS GENERATION_DIGEST GENERATION_DATABASE",
                    shell,
                )

    def test_test_output_mode_cannot_drift_in_either_direction(self):
        """Every site is pinned, and flipping any single one is rejected.

        Both directions matter. The lanes must not drift back to `all` and
        restore the 17318-line console; the benchmark harness must not be
        "made consistent" with them, because that rewrites a command block
        hashed verbatim as published benchmark evidence.
        """
        for action_name, expected, drift in (
            ("BazelCI", "errors", "all"),
            ("LargeIngestionGate", "errors", "all"),
            ("IntegrationBenchmark", "all", "errors"),
        ):
            action = named_action(action_name)
            sites = len(declared_test_output_modes(action))
            self.assertGreater(sites, 0)
            assert_test_output_mode(action, expected)
            for site in range(sites):
                with self.subTest(action=action_name, site=site):
                    drifted = with_test_output_mode(action, site, drift)
                    self.assertNotEqual(action, drifted)
                    with self.assertRaises(AssertionError):
                        assert_test_output_mode(drifted, expected)

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
          cleanup() { :; }
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
            'SRQL_FIXTURE_CA_URL: "https://srql-fixture-ca.carverauto.dev/ca.crt"',
            "export BAZEL_PROFILE=ci",
            "export SERVICERADAR_ENV=ci",
            "--strategy=TestRunner=local",
            "--//build:enable_integration_tests",
            "--//build:run_id=$RUN_ID",
            "--flaky_test_attempts=1",
            "--test_output=errors",
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

        assert_test_output_mode(action, "errors")

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
            "--test_output=errors",
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
            'RUN_DATABASE="sr_core_test_$RUN_ID"',
            'chmod 600 "$SERVICERADAR_FIXTURE_ENV_FILE"',
            "parse_prepare_json",
            self.generation_cleanup,
            self.generation_prepare,
            self.measured_migrate_command,
            self.generation_ready,
            "SERVICERADAR_SCHEMA_GENERATION_PREFLIGHT",
        ):
            self.assertIn(required, action)

        self.assert_clock_contract(action)
        prepare = action.index(self.generation_prepare)
        leased = action.index("GENERATION_LEASED=1", prepare)
        prepare_output = action.index('echo "$PREPARE_JSON"', prepare)
        self.assertLess(prepare, leased)
        self.assertLess(leased, prepare_output)
        for target in self.template_write_targets:
            self.assertNotIn(target, action)

    def assert_clock_contract(self, action: str) -> None:
        """The measured clock starts before the first thing it is supposed to measure.

        Split out of the preflight contract because only the trunk action has a preflight
        now, while every lifecycle has a clock.
        """
        measured_start = action.index("\n          RUN_ID=")
        fixture_setup = action.index("//:buildbuddy_setup_fixture_env", measured_start)
        prepare = action.index('PREPARE_JSON="$(bazel run', fixture_setup)
        ready = action.index('READY_JSON="$(bazel run', prepare)
        start_ns = action.index('START_NS="$(date +%s%N)"', ready)
        observer = action.index("//rust/integration-db:observe_connections", start_ns)
        self.assertLess(measured_start, start_ns)
        self.assertLess(fixture_setup, prepare)
        self.assertLess(prepare, ready)
        self.assertLess(ready, start_ns)
        self.assertLess(start_ns, observer)

    def assert_shared_template_is_never_written(self, action: str) -> None:
        """No active path to the shared template exists anywhere in the action.

        The invariant, stated where it can fail. A branch action that can advance
        sr_core_template poisons every other branch's clone source, and the failure surfaces
        on whichever branch runs next rather than on the branch that caused it.
        """
        for target in self.template_write_targets:
            self.assertNotIn(target, action)
        measured = measured_database_lifecycle_shell(action)
        self.assertEqual(2, measured.count("//rust/integration-db:prepare_generation"))
        self.assertEqual(1, measured.count("//elixir/serviceradar_core:migrate_generation"))
        self.assertEqual(1, measured.count("//rust/integration-db:cleanup_generations"))
        self.assertEqual(1, measured.count("//rust/integration-db:release_generation"))

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
            '//rust/integration-db:release_generation',
            'touch "$STOP_FILE"',
            'wait "$OBSERVER_PID"',
            'rm -f "$SERVICERADAR_FIXTURE_ENV_FILE"',
            'rm -rf "$OBSERVER_DIR"',
        ):
            self.assertIn(required, action)

        cleanup = action[action.index("cleanup() {") :]
        cleanup_lines = normalized_shell_lines(cleanup)
        self.assertEqual(
            1,
            cleanup_lines.count("bazel test $FLAGS //rust/integration-db:teardown_db"),
        )
        self.assertEqual(1, cleanup_lines.count(self.generation_release))
        original = cleanup.index("ORIGINAL_STATUS=$?")
        disable_trap = cleanup.index("trap - EXIT", original)
        nonfatal = cleanup.index("set +e", disable_trap)
        suite_complete = cleanup.index('touch "$SUITE_COMPLETE_FILE"', nonfatal)
        quiescent = cleanup.index(
            'wait_for_marker "$QUIESCENT_FILE" 30', suite_complete
        )
        teardown = cleanup.index("//rust/integration-db:teardown_db", quiescent)
        teardown_status = cleanup.index("TEARDOWN_STATUS=$?", teardown)
        release = cleanup.index("//rust/integration-db:release_generation", teardown_status)
        release_status = cleanup.index("RELEASE_STATUS=$?", release)
        end_ns = cleanup.index("END_NS=", release_status)
        stop = cleanup.index('touch "$STOP_FILE"', end_ns)
        observer_wait = cleanup.index('wait "$OBSERVER_PID"', stop)
        self.assertLess(original, disable_trap)
        self.assertLess(disable_trap, nonfatal)
        self.assertLess(suite_complete, quiescent)
        self.assertLess(quiescent, teardown)
        self.assertLess(teardown, teardown_status)
        self.assertLess(teardown_status, release)
        self.assertLess(release, release_status)
        self.assertLess(release_status, end_ns)
        self.assertLess(end_ns, stop)
        self.assertLess(stop, observer_wait)
        self.assertIn("LIFECYCLE_NS=$((END_NS - START_NS))", cleanup)
        self.assertIn("suite_status=$SUITE_STATUS", cleanup)
        self.assertIn("observer_status=$OBSERVER_STATUS", cleanup)
        self.assertIn("teardown_status=$TEARDOWN_STATUS", cleanup)
        self.assertIn("release_status=$RELEASE_STATUS", cleanup)
        self.assertIn("SUITE_STATUS=$ORIGINAL_STATUS", cleanup)

        status_init = action.index("SUITE_STATUS=0")
        cleanup_definition = action.index("cleanup() {", status_init)
        trap_install = action.index("trap cleanup EXIT", cleanup_definition)
        self.assertLess(status_init, cleanup_definition)
        self.assertLess(cleanup_definition, trap_install)

        suite_exit = cleanup.index('exit "$SUITE_STATUS"')
        observer_exit = cleanup.index('exit "$OBSERVER_STATUS"', suite_exit)
        teardown_exit = cleanup.index('exit "$TEARDOWN_STATUS"', observer_exit)
        release_exit = cleanup.index('exit "$RELEASE_STATUS"', teardown_exit)
        self.assertLess(suite_exit, observer_exit)
        self.assertLess(observer_exit, teardown_exit)
        self.assertLess(teardown_exit, release_exit)

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
        self.assertIn("pull_request:", header)
        # Parsed, not matched as a formatted string. The previous exact-substring form pinned
        # the comment-free, single-entry layout, so ADDING A BRANCH broke it -- and the branch
        # list is exactly the part of this block that is meant to change. What the contract
        # actually cares about is which branches trigger, so assert that.
        branch_block = header[header.index("branches:") :]
        branch_block = branch_block[: branch_block.index("\n\n")]
        branches = re.findall(r'^\s*-\s*"([^"]+)"', branch_block, re.M)
        self.assertIn("staging", branches)
        # usp-01-proposal is the long-lived unify-sweep-results-proto integration branch: PRs
        # land there first and reach staging much later, so a staging-only filter meant none of
        # this ran on them. Anything BEYOND these two is still a failure -- the point of the
        # gate is that heavy CI does not silently spread to other refs.
        self.assertLessEqual(set(branches), {"staging", "usp-01-proposal"})
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

        self.assert_shared_template_is_never_written(action)
        self.assert_common_measured_lifecycle(
            action,
            self.ordinary_provision,
            self.ordinary_suite,
            114,
        )
        self.assertEqual(1, action.count(self.ordinary_suite))
        self.assertNotIn(
            "bazel test $FLAGS //... "
            "--test_tag_filters=integration_test,-acceptance_test",
            action,
        )
        self.assert_clock_contract(action)
        self.assert_exact_measured_execution_order(
            action,
            self.ordinary_provision,
            self.ordinary_suite,
            114,
        )
        self.assert_observer_and_cleanup_contract(action)
        self.assert_teardown_suffix_mutations_are_rejected(action)
        commands = normalized_bazel_test_commands(action)
        self.assertEqual(
            (
                # The conditional preflight migrator targets the private generation.
                "bazel test $FLAGS //rust/integration-db:teardown_db",
                self.sweep,
                self.measured_migrate_command,
                self.ordinary_suite,
                self.web_db_suite,
            ),
            commands,
        )
        self.assertLess(action.index(self.ordinary_suite), action.index(self.web_db_suite))
        self.assertEqual(
            (self.ordinary_suite,),
            tuple(
                command
                for command in commands
                if "$FLAGS" in command and "//..." in command
            ),
        )

    def test_bazel_ci_runs_the_browser_acceptance_gate_once_before_database_setup(self):
        action = named_action("BazelCI")
        normalized_action = " ".join(action.split())
        unit_suite = (
            "bazel test -c opt --config=ci --//build:enable_integration_tests "
            "//... --test_tag_filters=-integration_test,-acceptance_test,-benchmark"
        )

        self.assertEqual(1, normalized_action.count(self.playwright_acceptance))
        self.assertLess(
            normalized_action.index(unit_suite),
            normalized_action.index(self.playwright_acceptance),
        )
        # The browser gate runs before the run id that pins keyed preflight and measurement.
        self.assertLess(
            normalized_action.index(self.playwright_acceptance),
            normalized_action.index('RUN_ID="$(od -An -tx1 -N4 /dev/urandom'),
        )

    def test_browser_gate_uses_only_the_digest_pinned_executor_browser(self):
        module_source = MODULE_FILE.read_text(encoding="utf-8")
        target_source = PLAYWRIGHT_BUILD.read_text(encoding="utf-8")

        self.assertNotIn("rules_playwright", module_source)
        self.assertNotIn("@web_ng_playwright", target_source)
        self.assertNotIn("playwright-browsers", target_source)
        self.assertIn('"PLAYWRIGHT_BROWSERS_PATH": "/ms-playwright"', target_source)
        self.assertIn(f'"container-image": "{PLAYWRIGHT_EXECUTOR_IMAGE}"', target_source)
        self.assertIn('"no-local"', target_source)
        self.assertIn('"no-remote-cache"', target_source)

    def test_godview_gate_runs_the_acceptance_for_an_in_area_change(self):
        """#4165: a godview-area PR still pays for the browser run."""
        for changed in (
            "elixir/web-ng/test/playwright/god_view_elk_scene.playwright.js",
            "elixir/web-ng/assets/js/lib/god_view/topology_overview_projection.js",
            "elixir/web-ng/native/god_view_nif/src/lib.rs",
            "buildbuddy.yaml",
        ):
            with self.subTest(changed=changed):
                status, log, invocations = run_godview_gate(
                    (changed, "rust/srql/src/main.rs")
                )
                self.assertEqual(0, status, log)
                self.assertEqual((self.acceptance_invocation,), invocations)

    def test_godview_gate_skips_the_acceptance_for_unrelated_changes(self):
        """#4165: the browser run is the cost an unrelated PR must not pay.

        The remote-tracking ref is absent by default, as it is on the runner:
        a gate that does not fetch its own base cannot reach this arm at all.
        """
        for remote_tracking_ref in (False, True):
            with self.subTest(remote_tracking_ref=remote_tracking_ref):
                status, log, invocations = run_godview_gate(
                    (
                        "go/cmd/tools/ubuntu-feed-merge/main.go",
                        "elixir/serviceradar_core/lib/serviceradar/foo.ex",
                        "elixir/web-ng/lib/serviceradar_web_ng_web/live/other_live.ex",
                        "elixir/web-ng/test/app_domain/topology/god_view_stream_test.exs",
                        "rust/srql/src/main.rs",
                        "helm/serviceradar/values.yaml",
                        ".github/workflows/web-ng-lint.yml",
                        "ci_heavy_gate_contract_test.py",
                    ),
                    remote_tracking_ref=remote_tracking_ref,
                )
                self.assertEqual(0, status, log)
                self.assertEqual((), invocations)
                self.assertIn("skipping acceptance", log)

    def test_godview_gate_fails_open_when_the_base_cannot_be_resolved(self):
        """A gate that cannot see the diff runs, never skips."""
        status, log, invocations = run_godview_gate(
            ("rust/srql/src/main.rs",), origin_reachable=False
        )

        self.assertEqual(0, status, log)
        self.assertEqual((self.acceptance_invocation,), invocations)
        self.assertIn("fail-open", log)

    def test_large_ingestion_gate_has_exact_independent_trigger(self):
        action = named_action("LargeIngestionGate")
        header = action[: action.index("    steps:")]
        self.assertIn(
            '    triggers:\n'
            '      push:\n'
            '        branches:\n'
            '          - "staging"\n'
            '      schedule:\n'
            '        crons:\n'
            '          - "0 2 * * *"\n',
            header,
        )
        self.assertNotIn("pull_request:", header)
        self.assertNotIn("tags:", header)
        self.assertNotIn('"v*"', header)

    def test_large_ingestion_gate_copies_runner_fixture_and_credential_scope(self):
        action = named_action("LargeIngestionGate")
        for required in (
            'OCI_REGISTRY: "registry.carverauto.dev"',
            'OCI_AUTH_REQUIRED: "1"',
            'SRQL_FIXTURE_CA_URL: "https://srql-fixture-ca.carverauto.dev/ca.crt"',
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
        self.assertNotIn(self.ordinary_provision, action)
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
                "bazel test $FLAGS //rust/integration-db:teardown_db",
                self.sweep,
                self.measured_migrate_command,
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

    def test_async_telemetry_handlers_are_callback_scoped(self):
        async_sources = {
            row["source"]
            for row in integration_dispositions()
            if row["mode"] == "async"
        }
        telemetry_sources = {
            source
            for source in async_sources
            if ":telemetry.attach"
            in (CORE_TEST_ROOT.parent / source).read_text(encoding="utf-8")
        }
        filtered_source = "test/serviceradar/inventory/agent_link_repair_worker_test.exs"

        self.assertEqual({filtered_source}, telemetry_sources)
        source = (CORE_TEST_ROOT.parent / filtered_source).read_text(encoding="utf-8")
        self.assertEqual(2, source.count(":telemetry.attach("))
        self.assertEqual(2, source.count("if metadata.agent_uid == agent_uid do"))

    def test_async_modules_do_not_mutate_vm_global_logger_configuration(self):
        for row in integration_dispositions():
            if row["mode"] != "async":
                continue

            block = module_source_block(row["source"], row["module"])
            self.assertNotIn("Logger.configure(", block, row)

    def test_async_on_exit_callbacks_are_non_database_cleanup_only(self):
        async_sources = {
            row["source"]
            for row in integration_dispositions()
            if row["mode"] == "async"
        }

        def on_exit_lines(source: str) -> tuple[str, ...]:
            return tuple(
                line.strip()
                for line in source.splitlines()
                if re.match(r"^\s*on_exit\s*\(", line)
            )

        sources_with_on_exit = {
            source
            for source in async_sources
            if on_exit_lines(
                (CORE_TEST_ROOT.parent / source).read_text(encoding="utf-8")
            )
        }

        self.assertEqual(ASYNC_ON_EXIT_ALLOWED_SOURCES, sources_with_on_exit)

        allowed_callbacks = {
            "test/serviceradar/integrations/armis_northbound_runner_test.exs": {
                "on_exit(stop_server)": 1,
            },
            "test/serviceradar/inventory/agent_link_repair_worker_test.exs": {
                "on_exit(fn -> :telemetry.detach(handler_id) end)": 8,
                "on_exit(fn -> :telemetry.detach(unresolved_handler) end)": 1,
            },
            "test/serviceradar/notifications/dispatcher_delivery_test.exs": {
                "on_exit(fn -> RateLimiter.reset(channel.id) end)": 2,
            },
        }

        for source, expected_lines in allowed_callbacks.items():
            text = (CORE_TEST_ROOT.parent / source).read_text(encoding="utf-8")
            actual_lines = on_exit_lines(text)
            self.assertEqual(sum(expected_lines.values()), len(actual_lines), source)
            self.assertEqual(set(expected_lines), set(actual_lines), source)
            for line, expected_count in expected_lines.items():
                self.assertEqual(expected_count, actual_lines.count(line), source)

    def test_async_sandbox_bypasses_the_singleton_rollup_lock_with_serial_coverage(self):
        support = TEST_SUPPORT.read_text(encoding="utf-8")
        baseline = PLATFORM_BASELINE.read_text(encoding="utf-8")
        setting = "platform.skip_inventory_rollup"

        self.assertIn(
            'configure_async_sandbox_transaction!(context)',
            support,
        )
        self.assertIn(
            "defp configure_async_sandbox_transaction!(%{async: true})",
            support,
        )
        self.assertEqual(
            1,
            support.count(
                f'ServiceRadar.Repo.query!("SET LOCAL {setting} = \'on\'")'
            ),
        )
        self.assertIn(
            f"current_setting('{setting}', true) = 'on'",
            baseline,
        )

        [configuration_row] = [
            row
            for row in integration_dispositions()
            if row["source"] == ASYNC_SANDBOX_CONFIGURATION_SOURCE
        ]
        self.assertEqual("async", configuration_row["mode"])
        configuration_source = (
            CORE_TEST_ROOT.parent / ASYNC_SANDBOX_CONFIGURATION_SOURCE
        ).read_text(encoding="utf-8")
        self.assertIn("use ServiceRadar.DataCase, async: true", configuration_source)
        self.assertIn(
            "ServiceRadar.TestSupport.checkout_repo!(context)",
            DATA_CASE.read_text(encoding="utf-8"),
        )
        self.assertIn(
            "SELECT current_setting('platform.skip_inventory_rollup', true)",
            configuration_source,
        )
        self.assertIn("DataCase.allow_sandbox(child)", configuration_source)

        [rollup_row] = [
            row
            for row in integration_dispositions()
            if row["source"] == INVENTORY_ROLLUP_TRIGGER_SOURCE
        ]
        self.assertEqual("serial", rollup_row["mode"])
        self.assertEqual("ddl", rollup_row["reason"])

        rollup_source = (
            CORE_TEST_ROOT.parent / INVENTORY_ROLLUP_TRIGGER_SOURCE
        ).read_text(encoding="utf-8")
        self.assertIn("use ServiceRadar.DataCase, async: false", rollup_source)
        self.assertIn("refresh_device_inventory_rollups", rollup_source)
        self.assertIn("device_inventory_counts", rollup_source)

        sandbox_regression = (
            CORE_TEST_ROOT / "serviceradar/test_support_sandbox_test.exs"
        ).read_text(encoding="utf-8")
        self.assertIn("async_total_before", sandbox_regression)
        self.assertIn("^async_total_before", sandbox_regression)
        self.assertIn(
            "serial_total_after == serial_total_before + 1",
            sandbox_regression,
        )

        rollup_tokens = (
            "refresh_device_inventory_rollups",
            "device_inventory_counts",
            "device_inventory_type_counts",
            "device_inventory_vendor_counts",
        )
        async_sources = {
            row["source"]
            for row in integration_dispositions()
            if row["mode"] == "async"
        }
        for source in async_sources:
            text = (CORE_TEST_ROOT.parent / source).read_text(encoding="utf-8")
            for token in rollup_tokens:
                self.assertNotIn(token, text, source)

    def test_integration_disposition_inventory_is_exhaustive_and_concrete(self):
        rows = integration_dispositions()
        selected = [row for row in rows if row["mode"] in SELECTED_MODES]
        load_only = [row for row in rows if row["mode"] == "load_only"]

        # Relations, not three pinned totals. These were 286 / 508 / 794 -- and
        # 286 + 508 == 794, so the only invariant was that selected and load_only
        # partition the inventory. Pinning the absolutes meant every added or
        # removed test file failed this gate even when the inventory was correct,
        # and made two concurrent PRs invalidate each other, since CI tests the
        # MERGE of a branch with its base. The set equality below is the real
        # exhaustiveness check and is not affected by how many tests exist.
        self.assertEqual(
            len(selected) + len(load_only),
            len(rows),
            "selected and load_only must partition the disposition inventory",
        )
        self.assertEqual(
            set(ordinary_core_test_sources()),
            {row["source"] for row in rows},
        )

        # Floors, as a tripwire against a truncated inventory. Deliberately far
        # below the real figures -- these are not counts to maintain.
        self.assertGreater(len(selected), 100, "selected inventory looks truncated")
        self.assertGreater(len(load_only), 100, "load_only inventory looks truncated")

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
            --timeout-seconds 5400 \\
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
        self.assertIn('Path(home) / ".local" / "bin"', library)
        self.assertIn('"/usr/local/bin", "/usr/bin", "/bin"', library)
        self.assertNotIn("top-secret", library + cli)
        for evidence in (
            "test_introduction_equality_with_markerless_release_is_deletion",
            "test_markerless_unrelated_release_is_divergent",
            "test_introduction_absent_repeated_or_malformed_fails",
            "test_marker_bearing_feature_commit_before_first_parent_merge_is_applicable",
            "test_exact_argv_slurp_shape_token_isolation_and_shell_false",
            "test_home_local_bin_is_prepended_when_home_is_set",
            "test_missing_and_pending_timeout_at_fake_1800_second_deadline",
            "test_same_tree_merge_success_qualifies_while_tag_sha_is_still_pending",
            "test_tag_sha_failure_does_not_fail_while_merge_sha_is_pending",
            "test_later_different_tree_descendant_is_ignored",
        ):
            self.assertIn(evidence, tests)

    def test_python_qualification_hardening_is_registered(self):
        library = RELEASE_GATE_LIBRARY.read_text(encoding="utf-8")
        cli = RELEASE_GATE_CLI.read_text(encoding="utf-8")
        tests = RELEASE_GATE_TEST.read_text(encoding="utf-8")

        self.assertIn("has_large_ingestion_target(target)", library)
        self.assertIn("has_large_ingestion_action(action)", library)
        self.assertIn("def qualification_commits(", library)
        self.assertIn("def tree_sha(self, commit: str) -> str:", library)
        self.assertIn("def first_parent_history(", library)
        self.assertIn("status_factory=lambda sha: GhStatusClient(", cli)
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
            "test_tree_sha_and_first_parent_history_argv",
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
            "Install GitHub CLI",
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
            "--timeout-seconds 5400",
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
    elif sys.argv[1:] == ["--hash-integration-cpu-diagnostic-inputs"]:
        print(cpu_diagnostic_input_hash())
    else:
        unittest.main()
