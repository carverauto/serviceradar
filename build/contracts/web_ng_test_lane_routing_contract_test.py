"""Static contract: every web-ng ExUnit test file is routed to a CI lane.

web-ng selects tests by tag across three lanes:

  * ``//elixir/web-ng:unit_tests``            -> ``:db_free`` (allow-list tier)
  * ``//elixir/web-ng:networks_live_db_test`` -> ``:web_ng_shared_fixture_db``
  * ``//elixir/web-ng:topology_atlas_db_test`` -> ``:topology_atlas_db``

Other ``ex_unit_test`` targets in ``//elixir/web-ng`` are lanes too, including
a manual target a workflow runs by name. A file that target lists in ``srcs``
is routed.

``test/test_helper.exs`` registers ``ServiceRadarWebNG.Test.LaneCoverageGuard``,
which fails the database-free lane at runtime when an individual test carries no
lane tag at all. Tag presence is that guard's job: this contract does not parse
test source. It checks the two routing facts a formatter cannot see:

  * a file is routed when the evaluated Bazel query puts it in any
    ``//elixir/web-ng`` ``ex_unit_test`` target's ``srcs``, or when the
    ``unit_tests`` glob loads it (everything under ``test/`` except
    ``test/integration`` and ``test/property``) -- unless the file is on
    the shared-fixture inventory, which is routed only by database-lane
    ``srcs`` membership (see db_selected);
  * files excluded from that glob and absent from every such target's
    evaluated ``srcs`` are never loaded, so each one must be listed below
    with a reason. A new such file fails this test until it is deliberately
    classified.

Lane membership is the ``srcs`` attribute of ``web_ng_lane_target_query``, not
the BUILD text. The two database lanes above must be present in that query;
every other ``ex_unit_test`` rule in it counts as well.

Selection is stricter than loading: the database-free lane excludes every
non-:db_free test at runtime, so a file carrying a database lane tag is
routed only when a database lane lists it in ``srcs`` (see db_selected).
Unit-glob loading alone leaves such a file unexecuted.
"""

import os
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path

from web_ng_db_runner_contract_test import SHARED_FIXTURE_SOURCES


def _runfiles_root():
    srcdir = os.environ.get("TEST_SRCDIR")
    if srcdir:
        return Path(srcdir) / os.environ.get("TEST_WORKSPACE", "_main")
    return Path(__file__).absolute().parents[1]


ROOT = _runfiles_root()
WEB_NG = ROOT / "elixir/web-ng"
LANE_QUERY = Path(
    os.environ.get(
        "WEB_NG_LANE_TARGET_QUERY",
        ROOT / "build/contracts/web_ng_lane_target_query",
    )
)

NETWORKS_TARGET = "//elixir/web-ng:networks_live_db_test"
TOPOLOGY_TARGET = "//elixir/web-ng:topology_atlas_db_test"
WEB_NG_LABEL = "//elixir/web-ng:"

DB_SELECTING_TARGETS = (NETWORKS_TARGET, TOPOLOGY_TARGET)

# Files under test/ that NO lane loads: excluded from the unit_tests glob and
# absent from every DB lane's srcs. Every entry needs a reason. A file leaves
# this list only by becoming runnable in a lane (tag it and add it to that
# lane's srcs where the lane declares one).
UNROUTED_TEST_SOURCES = {
    "test/integration/srql_nif_integration_test.exs":
        "env-gated (SRQL_INTEGRATION=1); needs a live database and the SRQL NIF",
    "test/integration/graph_cypher_integration_test.exs":
        "env-gated (SRQL_INTEGRATION=1); needs a live database with the AGE graph",
    "test/property/srql_property_test.exs":
        "property suite; exercises SRQL compilation paths that need the SRQL NIF",
}

GLOB_EXCLUDED_DIRS = ("test/integration/", "test/property/")


def test_files():
    return sorted(
        str(path.relative_to(WEB_NG))
        for path in (WEB_NG / "test").rglob("*_test.exs")
    )


def evaluated_lane_srcs(query_path):
    """Map each evaluated test target to the test sources Bazel put in its srcs.

    The two database lanes must be present. Every other rule in the query is a
    lane as well; callers union the values.
    """
    query = ET.parse(query_path)
    srcs = {}
    for rule in query.findall("rule"):
        attributes = {
            child.attrib["name"]: child
            for child in rule
            if "name" in child.attrib
        }
        src_node = attributes.get("srcs")
        values = [] if src_node is None else [
            item.attrib["value"] for item in src_node if "value" in item.attrib
        ]
        srcs[rule.attrib["name"]] = {
            value[len(WEB_NG_LABEL):]
            for value in values
            if value.startswith(WEB_NG_LABEL)
        }
    missing = [target for target in (NETWORKS_TARGET, TOPOLOGY_TARGET) if target not in srcs]
    if missing:
        raise AssertionError(
            "evaluated query %s has no rule for %s" % (query_path, ", ".join(missing))
        )
    return srcs


def lane_src_union(srcs):
    """Every test source any evaluated web-ng ex_unit_test target loads."""
    union = set()
    for values in srcs.values():
        union.update(values)
    return union


def _routed(source, lane_srcs, lane_srcs_by_target):
    if source in SHARED_FIXTURE_SOURCES:
        return db_selected(source, lane_srcs_by_target)
    if source in lane_srcs:
        return True
    return not source.startswith(GLOB_EXCLUDED_DIRS)


def db_selected(source, lane_srcs_by_target):
    """A database-tagged file is selected only when a database lane owns it."""
    return any(
        source in lane_srcs_by_target.get(target, set())
        for target in DB_SELECTING_TARGETS
    )


class WebNgTestLaneRoutingContractTest(unittest.TestCase):
    def setUp(self):
        self.files = test_files()
        self.lane_srcs_by_target = evaluated_lane_srcs(LANE_QUERY)
        self.lane_srcs = lane_src_union(self.lane_srcs_by_target)

    def test_evaluated_query_srcs_are_label_sets(self):
        import tempfile

        query = """<?xml version="1.0" encoding="UTF-8"?>
        <query>
          <rule name="//elixir/web-ng:networks_live_db_test" class="ex_unit_test">
            <list name="srcs">
              <label value="//elixir/web-ng:test/app_domain/accounts_test.exs"/>
              <string value="//other:ignored"/>
            </list>
          </rule>
          <rule name="//elixir/web-ng:topology_atlas_db_test" class="ex_unit_test">
            <list name="srcs">
              <label value="//elixir/web-ng:test/phoenix/topology/world_health_source_db_test.exs"/>
            </list>
          </rule>
          <rule name="//elixir/web-ng:mtr_reader_parity_test" class="ex_unit_test">
            <list name="srcs">
              <label value="//elixir/web-ng:test/integration/starrocks/mtr_reader_parity_test.exs"/>
            </list>
          </rule>
        </query>
        """
        handle = tempfile.NamedTemporaryFile("w", suffix=".xml", delete=False)
        handle.write(query)
        handle.close()
        self.addCleanup(os.remove, handle.name)
        srcs = evaluated_lane_srcs(handle.name)
        self.assertEqual(srcs[NETWORKS_TARGET], {"test/app_domain/accounts_test.exs"})
        self.assertEqual(
            srcs[TOPOLOGY_TARGET],
            {"test/phoenix/topology/world_health_source_db_test.exs"},
        )
        self.assertEqual(
            lane_src_union(srcs),
            {
                "test/app_domain/accounts_test.exs",
                "test/phoenix/topology/world_health_source_db_test.exs",
                "test/integration/starrocks/mtr_reader_parity_test.exs",
            },
        )

    def test_routing_decision_distinguishes_loading_from_selection(self):
        by_target = {
            NETWORKS_TARGET: {"test/app_domain/accounts_test.exs"},
            TOPOLOGY_TARGET: set(),
            "//elixir/web-ng:unit_tests": {
                "test/app_domain/accounts_test.exs",
                "test/plain_unit_test.exs",
                "test/phoenix/controllers/api/device_remove_facts_controller_test.exs",
            },
        }
        union = lane_src_union(by_target)
        self.assertTrue(_routed("test/app_domain/accounts_test.exs", union, by_target))
        self.assertTrue(_routed("test/plain_unit_test.exs", union, by_target))
        self.assertFalse(
            _routed(
                "test/phoenix/controllers/api/device_remove_facts_controller_test.exs",
                union,
                by_target,
            )
        )

    def test_every_file_is_routed_or_declared_unrouted(self):
        routed = []
        for source in self.files:
            if _routed(source, self.lane_srcs, self.lane_srcs_by_target):
                routed.append(source)
                self.assertNotIn(
                    source,
                    UNROUTED_TEST_SOURCES,
                    "%s is loaded by a lane and is also on UNROUTED_TEST_SOURCES. "
                    "Remove the inventory entry." % source,
                )
            elif source in UNROUTED_TEST_SOURCES:
                continue
            else:
                self.fail(
                    "%s is not in any evaluated web-ng test target's srcs, sits "
                    "outside the unit_tests glob, and is not on "
                    "UNROUTED_TEST_SOURCES. Route it by adding the file to the lane "
                    "target that should load it. If it genuinely cannot run in any "
                    "lane, add it to UNROUTED_TEST_SOURCES with a reason." % source
                )
        self.assertTrue(routed, "no routed test files found at all")

    def test_unrouted_inventory_has_no_stale_or_shadow_entries(self):
        known = set(self.files)
        for source, reason in UNROUTED_TEST_SOURCES.items():
            self.assertIn(source, known, "UNROUTED_TEST_SOURCES lists %s, which no longer exists" % source)
            self.assertTrue(
                source.startswith(GLOB_EXCLUDED_DIRS),
                "%s IS inside the unit_tests glob, so a lane loads it; "
                "do not exempt it, route it." % source,
            )
            self.assertNotIn(
                source,
                self.lane_srcs,
                "%s is on UNROUTED_TEST_SOURCES but an evaluated web-ng test "
                "target loads it. Remove the inventory entry." % source,
            )
            self.assertTrue(
                reason.strip(),
                "%s needs a non-empty reason for being unrouted" % source,
            )


if __name__ == "__main__":
    unittest.main()
