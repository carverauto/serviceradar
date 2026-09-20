#!/usr/bin/env python3
"""Pins what the published chart package carries.

`helm package` (run by the release workflow) applies .helmignore when it builds
the archive. This test parses .helmignore the way Helm's pkg/ignore does and
fails in both directions: ServiceRadar's own environment overlays, Argo CD
overrides and build/test sources must stay out of the package, and the files
operators are told to use from it must stay in.
"""

from pathlib import Path
import re
import unittest


CHART_DIR = Path(__file__).resolve().parent
HELMIGNORE = CHART_DIR / ".helmignore"

# Overlays operators are told to extract from the published chart. Every other
# values-*.yaml is an environment overlay and must not ship.
PUBLISHED_OVERLAYS = frozenset({"values-ha.yaml", "values-tenant.yaml"})

MUST_EXCLUDE = (
    "values-demo.yaml",
    "values-demo-staging.yaml",
    ".argocd-source-serviceradar-demo-prod.yaml",
    "BUILD.bazel",
    "helm_unittest_suite_test.py",
    "chart_package_contents_test.py",
    "tests/README.md",
    "tests/web_ng_mcp_enabled_test.yaml",
    # Left behind by running these tests directly with python3.
    "__pycache__/chart_package_contents_test.cpython-312.pyc",
)

MUST_INCLUDE = (
    "Chart.yaml",
    "values.yaml",
    "values-ha.yaml",
    "values-tenant.yaml",
    "README.md",
    "TENANT_RUNTIME.md",
    "templates/_helpers.tpl",
    "templates/web.yaml",
    "files/serviceradar-config.yaml",
    "dashboards/serviceradar-overview.json",
    "crds/spire.spiffe.io_clusterspiffeids.yaml",
    # Helm's convention for chart test hooks. Root-level build/test rules must
    # never reach into templates/.
    "templates/tests/test-connection.yaml",
    "charts/dgraph-24.1.4.tgz",
)


class Rule:
    """One .helmignore rule, parsed as helm's pkg/ignore parseRule does.

    - A trailing slash restricts the rule to directories.
    - A leading slash, or any other slash, matches the whole path relative to the
      chart root; a rule with no slash matches the base name only.
    - Matching uses Go's filepath.Match, where `*` and `?` never cross `/`.

    Constructs this mirror does not model are rejected, so a rule cannot pass
    here while helm behaves differently: `!` negation, `[` character classes
    (whose negation syntax differs between Go and Python) and `\\` escapes.
    Helm itself rejects `**`.
    """

    def __init__(self, raw):
        rule = raw
        if "**" in rule:
            raise ValueError(f"helm rejects ** in .helmignore: {raw!r}")
        for unsupported in ("!", "[", "\\"):
            if unsupported in rule:
                raise ValueError(f"{unsupported!r} is not modelled by this test: {raw!r}")
        self.directory_only = rule.endswith("/")
        if self.directory_only:
            rule = rule[: -len("/")]
        self.full_path = "/" in rule
        rule = rule[1:] if rule.startswith("/") else rule
        if not rule or rule.endswith("/"):
            raise ValueError(f"unsupported rule: {raw!r}")
        pattern = "".join(
            "[^/]*" if ch == "*" else "[^/]" if ch == "?" else re.escape(ch) for ch in rule
        )
        self.regex = re.compile(pattern + r"\Z")

    def matches(self, path, is_dir):
        if self.directory_only and not is_dir:
            return False
        subject = path if self.full_path else path.rsplit("/", 1)[-1]
        return self.regex.match(subject) is not None


def load_rules(text):
    return [
        Rule(line.strip())
        for line in text.splitlines()
        if line.strip() and not line.strip().startswith("#")
    ]


def is_ignored(rules, path):
    """True when helm would leave `path` out of the package.

    The directory loader walks the tree and skips an ignored directory entirely,
    so a file is excluded when it, or any directory above it, matches a rule.
    """
    parts = path.split("/")
    for depth in range(1, len(parts) + 1):
        candidate = "/".join(parts[:depth])
        is_dir = depth < len(parts)
        if any(rule.matches(candidate, is_dir) for rule in rules):
            return True
    return False


class ChartPackageContentsTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.rules = load_rules(HELMIGNORE.read_text(encoding="utf-8"))

    def test_rules_parse(self):
        self.assertTrue(self.rules, ".helmignore has no rules")

    def test_environment_overlays_and_build_sources_are_excluded(self):
        for path in MUST_EXCLUDE:
            with self.subTest(path=path):
                self.assertTrue(
                    is_ignored(self.rules, path),
                    f"{path} would ship in the published chart package",
                )

    def test_files_operators_use_from_the_package_are_kept(self):
        for path in MUST_INCLUDE:
            with self.subTest(path=path):
                self.assertFalse(
                    is_ignored(self.rules, path),
                    f"{path} would be dropped from the published chart package",
                )

    def test_every_values_overlay_present_is_classified(self):
        overlays = sorted(path.name for path in CHART_DIR.glob("values-*.yaml"))
        # Proves the directory listing saw the chart's overlays at all.
        self.assertIn("values-demo.yaml", overlays)
        for name in overlays:
            with self.subTest(overlay=name):
                if name in PUBLISHED_OVERLAYS:
                    self.assertFalse(is_ignored(self.rules, name))
                else:
                    self.assertTrue(
                        is_ignored(self.rules, name),
                        f"{name} is an environment overlay and would ship; add it to "
                        ".helmignore or to PUBLISHED_OVERLAYS if operators need it",
                    )

    def test_mirror_follows_go_matching(self):
        # Guards the mirror itself against the Python-vs-Go differences that
        # would let this test pass while helm packages something else.
        star = Rule("templates/*.py")
        self.assertFalse(star.matches("templates/sub/x.py", is_dir=False))
        self.assertTrue(star.matches("templates/x.py", is_dir=False))
        rooted = Rule("/tests/")
        self.assertTrue(rooted.matches("tests", is_dir=True))
        self.assertFalse(rooted.matches("templates/tests", is_dir=True))
        self.assertFalse(rooted.matches("tests", is_dir=False))
        base = Rule("BUILD.bazel")
        self.assertTrue(base.matches("templates/BUILD.bazel", is_dir=False))
        for bad in ("**/x.yaml", "[!v]alues.yaml", "!values-demo.yaml"):
            with self.subTest(rule=bad):
                with self.assertRaises(ValueError):
                    Rule(bad)


if __name__ == "__main__":
    unittest.main()
