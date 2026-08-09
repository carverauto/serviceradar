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

import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parent
BAZELRC = ROOT / ".bazelrc"
MAKEFILE = ROOT / "Makefile"
WORKFLOW = ROOT / "buildbuddy.yaml"
CACHE_PROXY_VALUES = ROOT / "k8s/buildbuddy/values-cache-proxy.yaml"


def active_bazelrc_lines(text: str, config: str) -> list[str]:
    prefix = f"build:{config} "
    return [
        line.strip()
        for line in text.splitlines()
        if line.strip().startswith(prefix) and not line.lstrip().startswith("#")
    ]


class BuildBuddyCacheProxyConfigTest(unittest.TestCase):
    def setUp(self):
        self.bazelrc = BAZELRC.read_text(encoding="utf-8")
        self.makefile = MAKEFILE.read_text(encoding="utf-8")
        self.workflow = WORKFLOW.read_text(encoding="utf-8")
        self.cache_proxy_values = CACHE_PROXY_VALUES.read_text(encoding="utf-8")

    def test_cache_proxy_profile_moves_only_cache_and_bytestream(self):
        self.assertEqual(
            active_bazelrc_lines(self.bazelrc, "cache_proxy"),
            [
                "build:cache_proxy "
                "--remote_cache=grpcs://cache-proxy.carverauto.dev:443",
                "build:cache_proxy "
                "--remote_bytestream_uri_prefix=carverauto.buildbuddy.io",
            ],
        )

        profile = "\n".join(active_bazelrc_lines(self.bazelrc, "cache_proxy"))
        for forbidden_option in (
            "--remote_executor",
            "--bes_backend",
            "--bes_results_url",
            "--remote_header",
        ):
            self.assertNotIn(forbidden_option, profile)

    def test_default_profiles_do_not_select_cache_proxy(self):
        for config in ("ci", "remote", "remote_base"):
            profile = "\n".join(active_bazelrc_lines(self.bazelrc, config))
            self.assertNotIn("--config=cache_proxy", profile)
            self.assertNotIn("cache-proxy.carverauto.dev", profile)

    def test_remote_override_import_stays_after_checked_in_profiles(self):
        active_lines = [
            line.strip()
            for line in self.bazelrc.splitlines()
            if line.strip() and not line.lstrip().startswith("#")
        ]
        remote_import = "try-import %workspace%/.bazelrc.remote"

        self.assertEqual(active_lines[-1], remote_import)
        import_index = active_lines.index(remote_import)
        for prefix in ("build:remote_base ", "build:ci ", "build:cache_proxy "):
            profile_indexes = [
                index
                for index, line in enumerate(active_lines)
                if line.startswith(prefix)
            ]
            self.assertTrue(profile_indexes, f"missing checked-in profile {prefix.strip()}")
            self.assertLess(max(profile_indexes), import_index)

    def test_make_aliases_inherit_canonical_recipes(self):
        expected_fragments = (
            "BAZEL_CI_FLAGS ?= -c opt --config=ci",
            "BAZEL_CACHE_PROXY_CONFIG ?= --config=cache_proxy",
            "BAZEL_WORKSPACE_BUILD_FLAGS ?= --config=remote",
            "BAZEL_WORKSPACE_TARGETS ?= //...",
            "BAZEL_UNIT_TEST_FLAGS ?= $(BAZEL_CI_FLAGS)",
            "BAZEL_UNIT_TEST_FILTERS ?= "
            "--test_tag_filters=-integration_test,-acceptance_test",
            "\t@$(BAZEL) build $(BAZEL_WORKSPACE_BUILD_FLAGS) "
            "$(BAZEL_WORKSPACE_TARGETS)",
            "build-workspace-cache: BAZEL_WORKSPACE_BUILD_FLAGS = "
            "$(BAZEL_CI_FLAGS) $(BAZEL_CACHE_PROXY_CONFIG)",
            "build-workspace-cache: build-workspace ##",
            "\t@$(BAZEL) test $(BAZEL_UNIT_TEST_FLAGS) "
            "$(BAZEL_WORKSPACE_TARGETS) $(BAZEL_UNIT_TEST_FILTERS)",
            "test-cache: BAZEL_UNIT_TEST_FLAGS = "
            "$(BAZEL_CI_FLAGS) $(BAZEL_CACHE_PROXY_CONFIG)",
            "test-cache: test ##",
        )
        for fragment in expected_fragments:
            self.assertIn(fragment, self.makefile)

        self.assertNotRegex(
            self.makefile,
            r"(?m)^\t.*bazel .*--config=cache_proxy",
            "cache aliases must inherit the canonical recipes instead of copying them",
        )

    def test_workflow_opt_in_remains_disabled_during_canary(self):
        active_opt_in = re.compile(
            r"(?m)^\s*printf ['\"]build:ci --config=cache_proxy"
        )
        self.assertIsNone(active_opt_in.search(self.workflow))
        self.assertNotIn("probe() {", self.workflow)
        self.assertNotIn("/dev/tcp/", self.workflow)

    def test_cache_proxy_backend_service_remains_private(self):
        self.assertRegex(
            self.cache_proxy_values,
            r"(?m)^service:\n  type: ClusterIP$",
        )
        self.assertNotRegex(
            self.cache_proxy_values,
            r"(?m)^\s*type:\s*LoadBalancer\s*$",
        )


if __name__ == "__main__":
    unittest.main()
