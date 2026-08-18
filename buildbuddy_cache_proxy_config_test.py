# Copyright 2026 Carver Automation Corporation.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

"""Guards the Bazel cache-proxy and database-integration routing.

The proxy is no longer an opt-in profile. `build:cache_only` owns cache/BES transport and
`build:remote_base` inherits it, so every CI or developer remote build takes the proxy path
with nothing to remember. The invariants below are the ones whose violation is silent or
misleading rather than obvious at the point of breakage.
"""

import os
import re
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parent
BAZELRC = ROOT / ".bazelrc"
MAKEFILE = ROOT / "Makefile"
WORKFLOW = ROOT / "buildbuddy.yaml"
MAIN_WORKFLOW = ROOT / ".forgejo/workflows/main.yml"
FORGEJO_INTEGRATION_WORKFLOW = (
    ROOT / ".forgejo/workflows/elixir-integration-sr-core.yml"
)
GITHUB_INTEGRATION_WORKFLOW = (
    ROOT / ".github/workflows/elixir-integration-sr-core.yml"
)
CACHE_PROXY_VALUES = ROOT / "k8s/buildbuddy/values-cache-proxy.yaml"
RELEASE_PIPELINE = ROOT / "build/buildbuddy/release_pipeline.sh"
DEMO_LOCAL_ROLLOUT = ROOT / ".agents/skills/demo-local-rollout/SKILL.md"
SRQL_FIXTURE_SKILL = ROOT / ".agents/skills/srql-fixtures-db-tests/SKILL.md"
FIXTURE_SETUP = ROOT / "buildbuddy_setup_fixture_env.sh"
FORGEJO_FIXTURE_SETUP = ROOT / "scripts/ci/configure-srql-fixture.sh"
PUSH_ALL_IMAGES = ROOT / "scripts/push_all_images.sh"

# The cache hop, and only the cache hop.
CACHE_PROXY_TARGET = "grpcs://cache-proxy.carverauto.dev:443"
# Execution, the build event stream, and the bytestream URIs written into it.
BUILDBUDDY_TARGET = "grpcs://carverauto.buildbuddy.io"
BYTESTREAM_PREFIX = "carverauto.buildbuddy.io"

# Build options apply to build and all commands that inherit from it, including test and run.
# A test-only profile does not make the same name valid for a build or run invocation.
BUILD_CONFIG_DEFINITION = re.compile(
    r"(?m)^(?:build|common):([A-Za-z0-9_-]+)\s"
)
TEST_CONFIG_DEFINITION = re.compile(
    r"(?m)^(?:build|common|test):([A-Za-z0-9_-]+)\s"
)
CONFIG_REFERENCE = re.compile(r"--config=([A-Za-z0-9_-]+)")
# `--config=` is not exclusively a Bazel flag -- the Makefile also runs
# `go run ./main.go --config=./.github/.testcoverage.yml`. Only lines that invoke bazel, or
# assign a BAZEL_* variable that feeds one, are in scope.
BAZEL_LINE = re.compile(r"\$\(BAZEL\)|\bbazel\b|^\s*BAZEL_[A-Z0-9_]*\s*\??=")


def active_lines(text: str) -> list[str]:
    """Non-blank, non-comment lines. Comments in these files carry examples and history."""
    return [
        line.strip()
        for line in text.splitlines()
        if line.strip() and not line.lstrip().startswith("#")
    ]


def write_test_ca(directory: Path) -> Path:
    """Issue a throwaway CA so fixture-setup tests can fetch a live PEM."""
    cert = directory / "live-ca.crt"
    key = directory / "live-ca.key"
    subprocess.run(
        [
            "openssl",
            "req",
            "-x509",
            "-newkey",
            "rsa:2048",
            "-keyout",
            str(key),
            "-out",
            str(cert),
            "-days",
            "3650",
            "-nodes",
            "-subj",
            "/CN=srql-fixture-test-ca",
        ],
        check=True,
        capture_output=True,
    )
    return cert


def active_bazelrc_lines(text: str, config: str) -> list[str]:
    prefix = f"build:{config} "
    return [line for line in active_lines(text) if line.startswith(prefix)]


def strip_comments(text: str, whole_line_only: bool) -> str:
    """Drop comment text so documented examples are not mistaken for live configuration."""
    out = []
    for line in text.splitlines():
        if line.lstrip().startswith("#"):
            continue
        out.append(line if whole_line_only else line.split("#", 1)[0])
    return "\n".join(out)


def continued_shell_lines(text: str) -> list[str]:
    """Join shell continuations embedded in workflow YAML into logical commands."""
    commands = []
    current = ""
    for raw in text.splitlines():
        line = raw.strip()
        current = f"{current} {line}".strip() if current else line
        if current.endswith("\\"):
            current = current[:-1].rstrip()
            continue
        commands.append(current)
        current = ""
    if current:
        commands.append(current)
    return commands


class BuildBuddyCacheProxyConfigTest(unittest.TestCase):
    def setUp(self):
        self.bazelrc = BAZELRC.read_text(encoding="utf-8")
        self.makefile = MAKEFILE.read_text(encoding="utf-8")
        self.workflow = WORKFLOW.read_text(encoding="utf-8")
        self.main_workflow = MAIN_WORKFLOW.read_text(encoding="utf-8")
        self.forgejo_integration_workflow = FORGEJO_INTEGRATION_WORKFLOW.read_text(
            encoding="utf-8"
        )
        self.github_integration_workflow = GITHUB_INTEGRATION_WORKFLOW.read_text(
            encoding="utf-8"
        )
        self.cache_proxy_values = CACHE_PROXY_VALUES.read_text(encoding="utf-8")
        self.release_pipeline = RELEASE_PIPELINE.read_text(encoding="utf-8")
        self.demo_local_rollout = DEMO_LOCAL_ROLLOUT.read_text(encoding="utf-8")
        self.srql_fixture_skill = SRQL_FIXTURE_SKILL.read_text(encoding="utf-8")
        self.push_all_images = PUSH_ALL_IMAGES.read_text(encoding="utf-8")

    def test_remote_base_inherits_cache_transport_and_owns_execution(self):
        """The proxy fronts the CAS/AC. Execution and BES must stay on BuildBuddy.

        A proxy named as --remote_executor or --bes_backend does not fail loudly: it is a
        BuildBuddy server too, so the RPCs are accepted and the build simply stops appearing
        where anyone looks for it.
        """
        cache_only = active_bazelrc_lines(self.bazelrc, "cache_only")
        remote_base = active_bazelrc_lines(self.bazelrc, "remote_base")
        cache_joined = "\n".join(cache_only)
        remote_joined = "\n".join(remote_base)

        self.assertIn(f"--remote_cache={CACHE_PROXY_TARGET}", cache_joined)
        self.assertIn(f"--bes_backend={BUILDBUDDY_TARGET}", cache_joined)
        self.assertIn("build:remote_base --config=cache_only", remote_base)
        self.assertIn(f"--remote_executor={BUILDBUDDY_TARGET}", remote_joined)

        for option in ("--remote_executor", "--bes_backend", "--bes_results_url"):
            for line in cache_only + remote_base:
                if f" {option}=" in line:
                    self.assertNotIn(
                        "cache-proxy.carverauto.dev",
                        line,
                        f"{option} must address BuildBuddy directly, not the cache proxy",
                    )

    def test_cache_only_does_not_select_execution_or_platform(self):
        """Database-facing tests may use the cache without becoming Linux RBE actions."""
        cache_only = "\n".join(active_bazelrc_lines(self.bazelrc, "cache_only"))

        for forbidden in (
            "--remote_executor=",
            "--host_platform=",
            "--platforms=",
            "--extra_execution_platforms=",
            "--extra_toolchains=",
            "--define=EXECUTOR=remote",
            "--java_runtime_version=remote",
            "--tool_java_runtime_version=remote",
            "--action_env=OPENSSL_",
        ):
            self.assertNotIn(forbidden, cache_only)

    def test_fixture_server_name_reaches_rust_and_elixir_tests(self):
        """NodePort clients verify the CNPG DNS certificate through both DB stacks."""
        database_env = [
            line
            for line in active_lines(self.bazelrc)
            if line.startswith("test:database_env ")
        ]

        self.assertTrue(
            any("--test_env=PGSSLSERVERNAME" in line for line in database_env)
        )
        self.assertTrue(
            any(
                "--test_env=SRQL_TEST_DATABASE_SERVER_NAME" in line
                for line in database_env
            )
        )

    def test_database_credentials_are_opt_in_and_never_enter_generic_remote_tests(self):
        """Fixture secrets belong only to explicit local, non-uploaded DB test actions."""
        active = active_lines(self.bazelrc)
        global_test = [line for line in active if line.startswith("test ")]
        database_env = [
            line for line in active if line.startswith("test:database_env ")
        ]

        for variable in (
            "SRQL_TEST_DATABASE_URL",
            "SRQL_TEST_ADMIN_URL",
            "SRQL_TEST_DATABASE_CA_CERT",
            "PGSSLROOTCERT",
            "CNPG_PASSWORD",
            "TEST_CNPG_PASSWORD",
            "NATS_URL",
            "NATS_KEY_B64",
        ):
            self.assertFalse(
                any(f"--test_env={variable}" in line for line in global_test),
                f"global test profile forwards credential-bearing {variable}",
            )
            if not variable.startswith("NATS_"):
                self.assertTrue(
                    any(f"--test_env={variable}" in line for line in database_env),
                    f"database_env does not forward required {variable}",
                )

        nats_env = [line for line in active if line.startswith("test:nats_env ")]
        self.assertTrue(any("--test_env=NATS_URL" in line for line in nats_env))
        self.assertTrue(any("--test_env=NATS_KEY_B64" in line for line in nats_env))
        self.assertIn("test:database_env --config=nats_env", active)

        joined = "\n".join(database_env)
        self.assertNotIn("--test_env=SERVICERADAR_TEST_DATABASE_URL", joined)
        self.assertNotIn("--test_env=SERVICERADAR_TEST_ADMIN_URL", joined)

        main_active = strip_comments(self.main_workflow, whole_line_only=True)
        self.assertNotIn("configure-srql-fixture.sh", main_active)
        self.assertNotIn("--config=database_env", main_active)
        self.assertNotRegex(
            main_active,
            r"--test_env=(?:SRQL|PGSSL|CNPG|TEST_CNPG|NATS)",
        )
        self.assertIn("--config=database_env", self.srql_fixture_skill)
        self.assertIn("credential_cleanup_status", self.srql_fixture_skill)

        self.assertIn("- 'integration_tests/srql/**'", self.forgejo_integration_workflow)

    def test_cache_proxy_endpoint_is_tls(self):
        """Public DNS plus the API key in a header means plaintext would leak the credential.

        The chart also serves plaintext gRPC on 1985; that port belongs to the in-cluster
        Service, never to a client.
        """
        self.assertTrue(
            CACHE_PROXY_TARGET.startswith("grpcs://"),
            "the cache proxy endpoint constant must be TLS",
        )
        for line in active_bazelrc_lines(self.bazelrc, "cache_only"):
            if "cache-proxy.carverauto.dev" in line:
                self.assertNotIn("grpc://", line.replace("grpcs://", ""))

    def test_bytestream_prefix_stays_on_buildbuddy(self):
        """Bazel writes bytestream:// URIs into the BES using the --remote_cache target.

        Left pointing at the proxy, BuildBuddy receives URIs for a host it cannot fetch from
        and build artifacts -- notably the timing profile -- fail to load in the UI. The
        build still succeeds, so nothing surfaces this but a missing profile.
        """
        joined = "\n".join(active_bazelrc_lines(self.bazelrc, "cache_only"))
        self.assertIn(f"--remote_bytestream_uri_prefix={BYTESTREAM_PREFIX}", joined)
        self.assertNotIn("--remote_bytestream_uri_prefix=cache-proxy", joined)
        self.assertNotIn(f"--remote_bytestream_uri_prefix=grpc", joined)

    def test_no_dangling_cache_proxy_config_references(self):
        """Every --config a build entrypoint names must be defined in the checked-in .bazelrc.

        Bazel treats an undefined config as a hard error, so this class of drift takes out a
        whole entrypoint rather than degrading it. It is exactly what happened when the
        `build:cache_proxy` profile was folded into `build:remote_base`: the profile went
        away while `Makefile` still passed `--config=cache_proxy`.

        Comments are excluded on purpose -- the READMEs and the workflow keep the historical
        opt-in as documentation, and documenting a removed flag is not a defect.
        """
        build_defined = set(BUILD_CONFIG_DEFINITION.findall(self.bazelrc))
        test_defined = set(TEST_CONFIG_DEFINITION.findall(self.bazelrc))
        self.assertIn("remote_base", build_defined, "sanity: .bazelrc parsed")
        self.assertIn("database_env", test_defined, "sanity: test config parsed")

        entrypoints = {
            "Makefile": strip_comments(self.makefile, whole_line_only=False),
            "buildbuddy.yaml": strip_comments(self.workflow, whole_line_only=True),
            "build/buildbuddy/release_pipeline.sh": strip_comments(
                self.release_pipeline, whole_line_only=False
            ),
            ".agents/skills/demo-local-rollout/SKILL.md": strip_comments(
                self.demo_local_rollout, whole_line_only=False
            ),
        }
        for name, text in entrypoints.items():
            for line in text.splitlines():
                if not BAZEL_LINE.search(line):
                    continue
                defined = (
                    test_defined
                    if re.search(r"\bbazel\s+test\b|\$\(BAZEL\)\s+test\b", line)
                    else build_defined
                )
                for referenced in CONFIG_REFERENCE.findall(line):
                    self.assertIn(
                        referenced,
                        defined,
                        f"{name} passes --config={referenced}, which no .bazelrc profile "
                        f"defines; Bazel fails the invocation outright",
                    )

        self.assertIn(
            'BAZEL_CONFIG="${BAZEL_CONFIG:-ci}"',
            self.push_all_images,
            "push_all_images must default to a defined Bazel profile",
        )

    def test_database_workflows_keep_test_actions_local_and_uncached(self):
        """Fixture DSNs and mutable outcomes must stay on each workflow runner."""
        labels = (
            "//rust/integration-db:sweep_stale_dbs",
            "//elixir/serviceradar_core:migrate_template",
            "//rust/integration-db:provision_db",
            "//rust/integration-db:teardown_db",
        )

        for workflow_name, workflow in (
            ("buildbuddy.yaml", self.workflow),
            ("Forgejo integration workflow", self.forgejo_integration_workflow),
            ("GitHub ARC integration workflow", self.github_integration_workflow),
        ):
            commands = continued_shell_lines(workflow)
            for label in labels:
                matches = [
                    command
                    for command in commands
                    if "bazel test" in command and label in command
                ]
                self.assertEqual(
                    len(matches),
                    1,
                    f"{workflow_name} must invoke {label} exactly once",
                )
                command = matches[0]
                for flag in (
                    "--config=database_env",
                    "--strategy=TestRunner=local",
                    "--nocache_test_results",
                    "--remote_upload_local_results=false",
                    "--//build:enable_integration_tests",
                    "--flaky_test_attempts=1",
                ):
                    self.assertIn(flag, command, f"{workflow_name} {label} lacks {flag}")

        buildbuddy_commands = continued_shell_lines(self.workflow)
        shard_commands = [
            command
            for command in buildbuddy_commands
            if "bazel test" in command
            and "--test_tag_filters=integration_test,-acceptance_test" in command
        ]
        self.assertEqual(len(shard_commands), 1)
        for flag in (
            "--config=database_env",
            "--strategy=TestRunner=local",
            "--nocache_test_results",
            "--remote_upload_local_results=false",
            "--//build:enable_integration_tests",
            "--flaky_test_attempts=1",
        ):
            self.assertIn(flag, shard_commands[0])

        forgejo_commands = continued_shell_lines(self.forgejo_integration_workflow)
        forgejo_suite = [
            command
            for command in forgejo_commands
            if "bazel test" in command
            and "//elixir/serviceradar_core:integration_tests" in command
        ]
        self.assertEqual(len(forgejo_suite), 1)
        self.assertIn("--config=database_env", forgejo_suite[0])
        self.assertIn("--flaky_test_attempts=1", forgejo_suite[0])

        github_commands = continued_shell_lines(self.github_integration_workflow)
        github_suite = [
            command
            for command in github_commands
            if "bazel test" in command
            and "//elixir/serviceradar_core:integration_tests" in command
        ]
        self.assertEqual(len(github_suite), 1)
        self.assertIn("--config=database_env", github_suite[0])
        self.assertIn("--flaky_test_attempts=1", github_suite[0])

        # //integration_tests/srql:* reaches buildbuddy.yaml through the wildcard asserted
        # above, not by name. Those targets were `manual`, which removed them from //...
        # expansion BEFORE tag filters were considered, so every caller had to list them by
        # hand; they carry `integration_test` now and the tag filter selects them.
        #
        # That wildcard command is asserted to be local and uncached a few lines up, which is
        # the property this test exists to protect. What is left to check is that it really
        # reaches them and cannot silently stop doing so.
        self.assertIn("//...", shard_commands[0])
        self.assertNotIn(
            "//integration_tests/srql:srql_api_test",
            "\n".join(buildbuddy_commands),
            "buildbuddy.yaml names an srql target explicitly again; either restore the "
            "per-target flag assertions here or drop the wildcard",
        )

        # The ARC workflow is not on the wildcard and still names them.
        for workflow_name, commands in (
            ("GitHub ARC integration workflow", github_commands),
        ):
            srql_commands = [
                command
                for command in commands
                if "bazel test" in command
                and "//integration_tests/srql:srql_api_test" in command
                and "//integration_tests/srql:srql_comprehensive_test" in command
            ]
            self.assertEqual(len(srql_commands), 1, workflow_name)
            for flag in (
                "--config=database_env",
                "--strategy=TestRunner=local",
                "--nocache_test_results",
                "--remote_upload_local_results=false",
                "--//build:enable_integration_tests",
                "--test_tag_filters=",
                "--flaky_test_attempts=1",
            ):
                self.assertIn(flag, srql_commands[0], workflow_name)

    def test_forgejo_database_workflow_fails_closed_without_fixture_credentials(self):
        """The authoritative database job cannot pass by silently skipping its suite."""
        workflow = self.forgejo_integration_workflow
        require_start = workflow.index("- name: Require SRQL fixture credentials")
        configure_start = workflow.index("- name: Configure SRQL fixture")
        sweep_start = workflow.index("- name: Sweep stale integration databases")
        self.assertLess(require_start, configure_start)
        self.assertLess(configure_start, sweep_start)

        require_block = workflow[require_start:configure_start]
        for variable in (
            "SRQL_TEST_DATABASE_URL",
            "SRQL_TEST_ADMIN_URL",
        ):
            self.assertIn(variable, require_block)
        self.assertNotIn("SRQL_TEST_DATABASE_CA_CERT", require_block)
        self.assertIn('test "${missing}" -eq 0', require_block)

        configure_block = workflow[configure_start:sweep_start]
        self.assertNotIn("if: ${{", configure_block)

        for step_name in (
            "Sweep stale integration databases",
            "Prepare template database",
            "Provision integration database",
            "serviceradar_core integration tests",
            "SRQL fixture integration tests",
        ):
            start = workflow.index(f"- name: {step_name}")
            next_step = workflow.find("\n      - name:", start + 1)
            block = workflow[start : next_step if next_step != -1 else None]
            self.assertNotIn("env.SRQL_TEST_", block, step_name)

        teardown_start = workflow.index("- name: Drop integration database")
        cleanup_start = workflow.index("- name: Remove fixture credential files")
        teardown_block = workflow[teardown_start:cleanup_start]
        self.assertIn("always()", teardown_block)
        self.assertIn("env.SRQL_TEST_DATABASE_URL != ''", teardown_block)
        self.assertIn("env.SRQL_TEST_ADMIN_URL != ''", teardown_block)
        self.assertIn("env.SRQL_TEST_DATABASE_CA_CERT != ''", teardown_block)

    def test_github_arc_workflow_fetches_live_ca_in_cluster(self):
        """GitHub ARC runners in carverauto must not pin a stored CA PEM."""
        workflow = self.github_integration_workflow
        self.assertIn("runs-on: arc-runner-set", workflow)
        self.assertNotIn("self-hosted, Linux, X64, arc-runner-set", workflow)
        self.assertIn(
            "http://srql-fixture-ca-incluster.srql-fixtures.svc.cluster.local/ca.crt",
            workflow,
        )
        self.assertIn("secrets.BUILDBUDDY_API_KEY", workflow)
        self.assertNotIn("secrets.SRQL_TEST_DATABASE_CA_CERT", workflow)
        require_start = workflow.index("- name: Require SRQL fixture credentials")
        configure_start = workflow.index("- name: Configure SRQL fixture")
        require_block = workflow[require_start:configure_start]
        self.assertNotIn("SRQL_TEST_DATABASE_CA_CERT", require_block)

    def test_buildbuddy_workflow_fetches_live_ca_in_cluster(self):
        """Self-hosted BB workflows must not take the fixture CA from the secret store."""
        workflow = self.workflow
        self.assertIn(
            "http://srql-fixture-ca-incluster.srql-fixtures.svc.cluster.local/ca.crt",
            workflow,
        )
        self.assertIn("A stored SRQL_TEST_DATABASE_CA_CERT is", workflow)
        setup = (ROOT / "buildbuddy_setup_fixture_env.sh").read_text(encoding="utf-8")
        self.assertIn("A stored SRQL_TEST_DATABASE_CA_CERT is not a source", setup)
        self.assertNotIn("Firecracker", setup)

    def test_buildbuddy_lifecycle_owns_identity_and_cleans_credentials(self):
        """Concurrent runs cannot share a DB name or leave credential files behind."""
        start = self.workflow.index("# The database lifecycle, deliberately ONE step.")
        end = self.workflow.index("# Largely a cache hit", start)
        lifecycle = self.workflow[start:end]

        self.assertIn("export GITHUB_RUN_ID=", lifecycle)
        self.assertIn("export GITHUB_RUN_ATTEMPT=1", lifecycle)
        self.assertIn('SERVICERADAR_FIXTURE_ENV_FILE="$(mktemp', lifecycle)
        self.assertIn(
            'rm -f "$GITHUB_OUTPUT" "$SERVICERADAR_FIXTURE_ENV_FILE"', lifecycle
        )
        self.assertNotIn("teardown_db || true", lifecycle)
        self.assertIn("credential_cleanup_status", lifecycle)
        self.assertIn(
            "unset SERVICERADAR_TEST_DATABASE_URL SERVICERADAR_TEST_ADMIN_URL",
            lifecycle,
        )

    def test_fixture_setup_enforces_verified_tls_without_logging_credentials(self):
        """Pre-set BuildBuddy DSNs become verify-full and keep their password private."""
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            fake_bin = tmp_path / "bin"
            fake_bin.mkdir()
            fake_kubectl = fake_bin / "kubectl"
            fake_kubectl.write_text("#!/bin/sh\nexit 1\n", encoding="utf-8")
            fake_kubectl.chmod(0o700)
            live_ca = write_test_ca(tmp_path)
            env_file = tmp_path / "fixture.env"
            secret = "fixture-secret"
            raw_at_secret = "raw-at-secret"
            query_secret = "fixture-query-secret"
            fragment_secret = "fixture-fragment-secret"
            server_name = "srql-fixture-rw.srql-fixtures.svc.cluster.local"
            env = os.environ.copy()
            env.update(
                {
                    "PATH": f"{fake_bin}:/usr/bin:/bin",
                    "SERVICERADAR_FIXTURE_ENV_FILE": str(env_file),
                    "SRQL_FIXTURE_CA_URL": live_ca.as_uri(),
                    "SRQL_TEST_DATABASE_URL": (
                        f"postgres://app:{secret}@{raw_at_secret}@fixture.example:5432/srql_fixture"
                    ),
                    "SRQL_TEST_ADMIN_URL": (
                        "postgres://admin@fixture.example:5432/postgres"
                        f"?password=@{query_secret}&application_name=cache-test"
                    ),
                    "SRQL_TEST_DATABASE_CA_CERT": "not-a-real-certificate",
                    "SRQL_TEST_DATABASE_SERVER_NAME": server_name,
                }
            )

            result = subprocess.run(
                ["/bin/bash", str(FIXTURE_SETUP)],
                cwd=ROOT,
                env=env,
                capture_output=True,
                text=True,
                check=False,
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertNotIn(secret, result.stdout)
            self.assertNotIn(secret, result.stderr)
            self.assertNotIn(raw_at_secret, result.stdout)
            self.assertNotIn(raw_at_secret, result.stderr)
            self.assertNotIn(query_secret, result.stdout)
            self.assertNotIn(query_secret, result.stderr)
            self.assertNotIn(fragment_secret, result.stdout)
            self.assertNotIn(fragment_secret, result.stderr)
            self.assertEqual(stat.S_IMODE(env_file.stat().st_mode), 0o600)
            contents = env_file.read_text(encoding="utf-8")
            self.assertEqual(contents.count("sslmode=verify-full"), 2)
            self.assertIn("BEGIN CERTIFICATE", contents)
            self.assertNotIn("not-a-real-certificate", contents)
            self.assertTrue(
                f"SRQL_TEST_DATABASE_SERVER_NAME='{server_name}'" in contents
            )
            self.assertTrue(f"PGSSLSERVERNAME='{server_name}'" in contents)

            stored_only = env.copy()
            stored_only["SERVICERADAR_FIXTURE_ENV_FILE"] = str(
                tmp_path / "stored-only.env"
            )
            stored_only["SRQL_FIXTURE_CA_URL"] = (
                tmp_path / "missing-ca.crt"
            ).as_uri()
            stored_only["SRQL_TEST_DATABASE_CA_CERT"] = live_ca.read_text(
                encoding="utf-8"
            )
            stored = subprocess.run(
                ["/bin/bash", str(FIXTURE_SETUP)],
                cwd=ROOT,
                env=stored_only,
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertNotEqual(stored.returncode, 0)
            self.assertIn("ignored on purpose", stored.stderr)
            self.assertFalse((tmp_path / "stored-only.env").exists())

            fragment_env = env.copy()
            fragment_env["SERVICERADAR_FIXTURE_ENV_FILE"] = str(
                tmp_path / "fragment.env"
            )
            fragment_env["SRQL_TEST_DATABASE_URL"] = (
                "postgres://app@fixture.example:5432/srql_fixture"
                f"#{fragment_secret}"
            )
            fragment = subprocess.run(
                ["/bin/bash", str(FIXTURE_SETUP)],
                cwd=ROOT,
                env=fragment_env,
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertNotEqual(fragment.returncode, 0)
            self.assertIn("must not contain fragments", fragment.stderr)
            self.assertNotIn(fragment_secret, fragment.stdout)
            self.assertNotIn(fragment_secret, fragment.stderr)

            downgrade_env = env.copy()
            downgrade_env["SERVICERADAR_FIXTURE_ENV_FILE"] = str(
                tmp_path / "downgraded.env"
            )
            downgrade_env["SRQL_FIXTURE_SSLMODE"] = "require"
            downgrade = subprocess.run(
                ["/bin/bash", str(FIXTURE_SETUP)],
                cwd=ROOT,
                env=downgrade_env,
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertNotEqual(downgrade.returncode, 0)
            self.assertIn("must be verify-full", downgrade.stderr)

    def test_forgejo_fixture_setup_normalizes_tls_without_printing_credentials(self):
        """Forgejo's client-side materializer enforces the same verified-TLS contract."""
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            github_env = tmp_path / "github.env"
            live_ca = write_test_ca(tmp_path)
            fake_bin = tmp_path / "bin"
            fake_bin.mkdir()
            fake_kubectl = fake_bin / "kubectl"
            fake_kubectl.write_text("#!/bin/sh\nexit 1\n", encoding="utf-8")
            fake_kubectl.chmod(0o700)
            secret = "forgejo-db-secret"
            admin_secret = "forgejo-admin-secret"
            server_name = "srql-fixture-rw.srql-fixtures.svc.cluster.local"
            env = os.environ.copy()
            env.update(
                {
                    "PATH": f"{fake_bin}:/usr/bin:/bin",
                    "RUNNER_TEMP": str(tmp_path),
                    "GITHUB_ENV": str(github_env),
                    "SRQL_FIXTURE_CA_URL": live_ca.as_uri(),
                    "SRQL_TEST_DATABASE_URL": (
                        f"postgres://app:{secret}@192.0.2.10:5432/srql_fixture"
                        "?application_name=forgejo-test"
                    ),
                    "SRQL_TEST_ADMIN_URL": (
                        f"postgres://admin:{admin_secret}@192.0.2.10:5432/postgres"
                        "?sslmode=require"
                    ),
                    "SRQL_TEST_DATABASE_CA_CERT": "not-a-real-certificate",
                    "SRQL_TEST_DATABASE_SERVER_NAME": server_name,
                }
            )

            result = subprocess.run(
                ["/bin/bash", str(FORGEJO_FIXTURE_SETUP)],
                cwd=ROOT,
                env=env,
                capture_output=True,
                text=True,
                check=False,
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            for value in (secret, admin_secret):
                self.assertNotIn(value, result.stdout)
                self.assertNotIn(value, result.stderr)

            contents = github_env.read_text(encoding="utf-8")
            self.assertIn("BEGIN CERTIFICATE", contents)
            self.assertNotIn("not-a-real-certificate", contents)
            self.assertEqual(contents.count("sslmode=verify-full"), 2)
            for assignment in (
                f"SRQL_TEST_DATABASE_SERVER_NAME={server_name}",
                f"SERVICERADAR_TEST_DATABASE_SERVER_NAME={server_name}",
                f"PGSSLSERVERNAME={server_name}",
                "CNPG_SSL_MODE=verify-full",
            ):
                self.assertIn(assignment, contents)
            self.assertEqual(
                stat.S_IMODE((tmp_path / "srql-fixture-ca.crt").stat().st_mode),
                0o600,
            )

    def test_darwin_image_publish_never_uses_host_native_cache_only_artifacts(self):
        """A Darwin target platform cannot be packaged into Linux/amd64 OCI images."""
        for source_name, source in (
            ("Makefile", self.makefile),
            ("demo-local-rollout skill", self.demo_local_rollout),
        ):
            for line in source.splitlines():
                if "_push" in line:
                    self.assertNotIn("--config=cache_only", line, source_name)

        self.assertIn("use 'make push_all' on macOS", self.makefile)
        self.assertIn("On macOS use", self.demo_local_rollout)

    def test_fixture_setup_requires_a_caller_owned_output_path(self):
        """Direct helper use cannot fall back to one shared credential-bearing /tmp file."""
        env = os.environ.copy()
        env.pop("SERVICERADAR_FIXTURE_ENV_FILE", None)

        result = subprocess.run(
            ["/bin/bash", str(FIXTURE_SETUP)],
            cwd=ROOT,
            env=env,
            capture_output=True,
            text=True,
            check=False,
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("must name a caller-owned temporary file", result.stderr)
        self.assertNotIn("/tmp/serviceradar-fixture-env", result.stderr)

    def test_remote_override_import_stays_last(self):
        """An rc file can only override configs defined before it.

        The import sat ~80 lines above `build:remote_base` once. A CI job's
        `.bazelrc.remote` override expanded first and `remote_base` overwrote --remote_cache
        straight back, silently, with the build looking entirely normal.
        """
        lines = active_lines(self.bazelrc)
        remote_import = "try-import %workspace%/.bazelrc.remote"

        self.assertEqual(lines[-1], remote_import)
        import_index = lines.index(remote_import)
        for prefix in ("build:cache_only ", "build:remote_base ", "build:ci "):
            indexes = [i for i, line in enumerate(lines) if line.startswith(prefix)]
            self.assertTrue(indexes, f"missing checked-in profile {prefix.strip()}")
            self.assertLess(max(indexes), import_index)

    def test_make_aliases_inherit_canonical_recipes(self):
        """The cache aliases must reuse the canonical recipes, not restate them.

        A copied recipe drifts from the command CI and developers actually run, which is the
        one thing these aliases exist to prevent.
        """
        for fragment in (
            "BAZEL_CI_FLAGS ?= -c opt --config=ci",
            "BAZEL_WORKSPACE_BUILD_FLAGS ?= $(BAZEL_CI_FLAGS)",
            "BAZEL_WORKSPACE_TARGETS ?= //...",
            "BAZEL_UNIT_TEST_FLAGS ?= $(BAZEL_CI_FLAGS)",
            "BAZEL_UNIT_TEST_FILTERS ?= "
            "--test_tag_filters=-integration_test,-acceptance_test",
            "\t@$(BAZEL) build $(BAZEL_WORKSPACE_BUILD_FLAGS) "
            "$(BAZEL_WORKSPACE_TARGETS)",
            "\t@$(BAZEL) test $(BAZEL_UNIT_TEST_FLAGS) "
            "$(BAZEL_WORKSPACE_TARGETS) $(BAZEL_UNIT_TEST_FILTERS)",
        ):
            self.assertIn(fragment, self.makefile)

    def test_workflow_writes_no_bazelrc_remote_override(self):
        """The workflow must not hand-write a cache override into .bazelrc.remote.

        It routes through the proxy by inheriting `build:remote_base` like everything else.
        An opt-in line here would name a profile that no longer exists and fail the run
        before any target is built.
        """
        active = strip_comments(self.workflow, whole_line_only=True)
        self.assertNotRegex(active, r"printf\s+['\"]build:\w+\s+--config=")
        self.assertNotIn("probe() {", active)
        self.assertNotIn("/dev/tcp/", active)

    def test_cache_proxy_backend_service_remains_private(self):
        """The Envoy edge is the only public door. The Service behind it stays ClusterIP.

        It shipped as `LoadBalancer` with MetalLB annotations once and answered plaintext
        gRPC on 192.168.6.86:1985 across the LAN for 2d18h. The chart's own default is
        `LoadBalancer`, so an upgrade that loses this file re-exposes it.
        """
        self.assertRegex(self.cache_proxy_values, r"(?m)^service:\n  type: ClusterIP$")
        self.assertNotRegex(self.cache_proxy_values, r"(?m)^\s*type:\s*LoadBalancer\s*$")


if __name__ == "__main__":
    unittest.main()
