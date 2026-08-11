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

"""Guards the Bazel cache-proxy routing.

The proxy is no longer an opt-in profile. `build:remote_base` sends --remote_cache to the
shared Envoy edge, so EVERY remote build -- CI, --config=remote, and a developer laptop --
takes the proxy path with nothing to remember. The invariants below are the ones whose
violation is silent or misleading rather than obvious at the point of breakage.
"""

import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parent
BAZELRC = ROOT / ".bazelrc"
MAKEFILE = ROOT / "Makefile"
WORKFLOW = ROOT / "buildbuddy.yaml"
CACHE_PROXY_VALUES = ROOT / "k8s/buildbuddy/values-cache-proxy.yaml"

# The cache hop, and only the cache hop.
CACHE_PROXY_TARGET = "grpcs://cache-proxy.carverauto.dev:443"
# Execution, the build event stream, and the bytestream URIs written into it.
BUILDBUDDY_TARGET = "grpcs://carverauto.buildbuddy.io"
BYTESTREAM_PREFIX = "carverauto.buildbuddy.io"

# `build:foo`, `test:foo`, `common:foo`, ... -- every form that defines a --config value.
CONFIG_DEFINITION = re.compile(
    r"(?m)^(?:build|test|common|run|query|fetch|coverage|cquery|aquery|mod):([A-Za-z0-9_-]+)\s"
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


class BuildBuddyCacheProxyConfigTest(unittest.TestCase):
    def setUp(self):
        self.bazelrc = BAZELRC.read_text(encoding="utf-8")
        self.makefile = MAKEFILE.read_text(encoding="utf-8")
        self.workflow = WORKFLOW.read_text(encoding="utf-8")
        self.cache_proxy_values = CACHE_PROXY_VALUES.read_text(encoding="utf-8")

    def test_remote_base_sends_only_the_cache_to_the_proxy(self):
        """The proxy fronts the CAS/AC. Execution and BES must stay on BuildBuddy.

        A proxy named as --remote_executor or --bes_backend does not fail loudly: it is a
        BuildBuddy server too, so the RPCs are accepted and the build simply stops appearing
        where anyone looks for it.
        """
        remote_base = active_bazelrc_lines(self.bazelrc, "remote_base")
        joined = "\n".join(remote_base)

        self.assertIn(f"--remote_cache={CACHE_PROXY_TARGET}", joined)
        self.assertIn(f"--remote_executor={BUILDBUDDY_TARGET}", joined)
        self.assertIn(f"--bes_backend={BUILDBUDDY_TARGET}", joined)

        for option in ("--remote_executor", "--bes_backend", "--bes_results_url"):
            for line in remote_base:
                if line.startswith(f"build:remote_base {option}="):
                    self.assertNotIn(
                        "cache-proxy.carverauto.dev",
                        line,
                        f"{option} must address BuildBuddy directly, not the cache proxy",
                    )

    def test_cache_proxy_endpoint_is_tls(self):
        """Public DNS plus the API key in a header means plaintext would leak the credential.

        The chart also serves plaintext gRPC on 1985; that port belongs to the in-cluster
        Service, never to a client.
        """
        self.assertTrue(
            CACHE_PROXY_TARGET.startswith("grpcs://"),
            "the cache proxy endpoint constant must be TLS",
        )
        for line in active_bazelrc_lines(self.bazelrc, "remote_base"):
            if "cache-proxy.carverauto.dev" in line:
                self.assertNotIn("grpc://", line.replace("grpcs://", ""))

    def test_bytestream_prefix_stays_on_buildbuddy(self):
        """Bazel writes bytestream:// URIs into the BES using the --remote_cache target.

        Left pointing at the proxy, BuildBuddy receives URIs for a host it cannot fetch from
        and build artifacts -- notably the timing profile -- fail to load in the UI. The
        build still succeeds, so nothing surfaces this but a missing profile.
        """
        joined = "\n".join(active_bazelrc_lines(self.bazelrc, "remote_base"))
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
        defined = set(CONFIG_DEFINITION.findall(self.bazelrc))
        self.assertIn("remote_base", defined, "sanity: .bazelrc parsed")

        entrypoints = {
            "Makefile": strip_comments(self.makefile, whole_line_only=False),
            "buildbuddy.yaml": strip_comments(self.workflow, whole_line_only=True),
        }
        for name, text in entrypoints.items():
            for line in text.splitlines():
                if not BAZEL_LINE.search(line):
                    continue
                for referenced in CONFIG_REFERENCE.findall(line):
                    self.assertIn(
                        referenced,
                        defined,
                        f"{name} passes --config={referenced}, which no .bazelrc profile "
                        f"defines; Bazel fails the invocation outright",
                    )

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
        for prefix in ("build:remote_base ", "build:ci "):
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
            "BAZEL_WORKSPACE_BUILD_FLAGS ?= --config=remote",
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
