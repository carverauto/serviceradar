"""Static contract: every web-ng ExUnit test file is routed to a CI lane.

web-ng selects tests by tag across three lanes:

  * ``//elixir/web-ng:unit_tests``            -> ``:db_free`` (allow-list tier)
  * ``//elixir/web-ng:networks_live_db_test`` -> ``:web_ng_shared_fixture_db``
  * ``//elixir/web-ng:topology_atlas_db_test`` -> ``:topology_atlas_db``

``test/test_helper.exs`` registers ``ServiceRadarWebNG.Test.LaneCoverageGuard``,
which fails the database-free lane at RUNTIME when an individual test carries no
lane tag at all. This contract is the static half of the same guarantee, and it
owns the two things a formatter cannot see:

  * a test tagged for a DB lane runs only if its FILE is in that lane's ``srcs``
    -- tag presence and target membership must agree in both directions;
  * files excluded from the ``unit_tests`` glob entirely (``test/integration``,
    ``test/property``) are never loaded by any lane, so they are only honest when
    each one is listed below with a reason. A new such file fails this test until
    it is deliberately classified.
"""

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
WEB_NG = ROOT / "elixir/web-ng"
BUILD = WEB_NG / "BUILD.bazel"

LANE_TAGS = ("db_free", "web_ng_shared_fixture_db", "topology_atlas_db")

# Files under test/ that NO lane loads: excluded from the unit_tests glob and
# absent from every DB lane's srcs. Every entry needs a reason. A file leaves
# this list only by becoming runnable in a lane (tag it and add it to that
# lane's srcs where the lane declares one).
UNROUTED_TEST_SOURCES = {
    "test/integration/srql_nif_integration_test.exs":
        "env-gated (SRQL_INTEGRATION=1); needs a live database and the SRQL NIF",
    "test/integration/graph_cypher_integration_test.exs":
        "env-gated (SRQL_INTEGRATION=1); needs a live database with the AGE graph",
    "test/property/api_query_controller_property_test.exs":
        "property suite; exercises SRQL compilation paths that need the SRQL NIF",
    "test/property/srql_property_test.exs":
        "property suite; exercises SRQL compilation paths that need the SRQL NIF",
    "test/property/srql_query_input_property_test.exs":
        "property suite; exercises SRQL compilation paths that need the SRQL NIF",
    "test/property/edge_onboarding_token_property_test.exs":
        "property suite; exercises SRQL compilation paths that need the SRQL NIF",
}

GLOB_EXCLUDED_DIRS = ("test/integration/", "test/property/")


def build_srcs(target):
    match = re.search(
        r'name = "%s".*?srcs = \[(.*?)\]' % target, BUILD.read_text(), re.S
    )
    if not match:
        raise AssertionError("target %s not found in %s" % (target, BUILD))
    return set(re.findall(r'"(test/[^"]+)"', match.group(1)))


def test_files():
    return sorted(
        str(path.relative_to(WEB_NG))
        for path in (WEB_NG / "test").rglob("*_test.exs")
    )


def lane_tags_in(source):
    text = (WEB_NG / source).read_text()
    tags = set()
    for tag in LANE_TAGS:
        if re.search(r"@(moduletag|tag|describetag)\s+:%s\b" % tag, text):
            tags.add(tag)
    return tags


class WebNgTestLaneRoutingContractTest(unittest.TestCase):
    def setUp(self):
        self.files = test_files()
        self.networks_srcs = build_srcs("networks_live_db_test")
        self.topology_srcs = build_srcs("topology_atlas_db_test")

    def test_every_file_is_routed_or_declared_unrouted(self):
        routed = []
        unrouted = []
        for source in self.files:
            tags = lane_tags_in(source)
            if tags:
                routed.append(source)
            elif source in UNROUTED_TEST_SOURCES:
                unrouted.append(source)
            else:
                self.fail(
                    "%s carries no lane tag (%s) and is not on UNROUTED_TEST_SOURCES. "
                    "Route it: @moduletag :db_free when it needs no database, "
                    "@moduletag :web_ng_shared_fixture_db (plus the networks_live_db_test "
                    "srcs list and web_ng_db_runner_contract_test.py) when it does. "
                    "If it genuinely cannot run in any lane, add it to "
                    "UNROUTED_TEST_SOURCES with a reason."
                    % (source, ", ".join(":" + t for t in LANE_TAGS))
                )
        self.assertTrue(routed, "no routed test files found at all")

    def test_db_lane_tag_implies_srcs_membership(self):
        for source in self.files:
            tags = lane_tags_in(source)
            if "web_ng_shared_fixture_db" in tags:
                self.assertIn(
                    source,
                    self.networks_srcs,
                    "%s tags :web_ng_shared_fixture_db but is not a src of "
                    "//elixir/web-ng:networks_live_db_test, so that lane never loads "
                    "it and no lane runs those tests." % source,
                )
            if "topology_atlas_db" in tags:
                self.assertIn(
                    source,
                    self.topology_srcs,
                    "%s tags :topology_atlas_db but is not a src of "
                    "//elixir/web-ng:topology_atlas_db_test." % source,
                )

    def test_db_lane_srcs_are_tagged(self):
        for source in self.networks_srcs:
            self.assertIn(
                "web_ng_shared_fixture_db",
                lane_tags_in(source),
                "%s is a src of networks_live_db_test but no test in it is tagged "
                ":web_ng_shared_fixture_db, so the lane loads it and selects "
                "nothing from it." % source,
            )
        for source in self.topology_srcs:
            self.assertIn(
                "topology_atlas_db",
                lane_tags_in(source),
                "%s is a src of topology_atlas_db_test but no test in it is tagged "
                ":topology_atlas_db." % source,
            )

    def test_unrouted_inventory_has_no_stale_or_shadow_entries(self):
        known = set(self.files)
        for source, reason in UNROUTED_TEST_SOURCES.items():
            self.assertIn(source, known, "UNROUTED_TEST_SOURCES lists %s, which no longer exists" % source)
            self.assertTrue(
                source.startswith(GLOB_EXCLUDED_DIRS),
                "%s IS inside the unit_tests glob, so it can carry a lane tag; "
                "do not exempt it, route it." % source,
            )
            self.assertTrue(
                reason.strip(),
                "%s needs a non-empty reason for being unrouted" % source,
            )
        # Files carrying a lane tag must not sit on the unrouted inventory.
        for source in UNROUTED_TEST_SOURCES:
            self.assertFalse(
                lane_tags_in(source),
                "%s is on UNROUTED_TEST_SOURCES but carries a lane tag; remove "
                "the inventory entry." % source,
            )


if __name__ == "__main__":
    unittest.main()
