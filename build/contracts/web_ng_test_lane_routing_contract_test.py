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

Lane tags are the atoms ExUnit actually registers: ``@moduletag``, ``@tag``, and
``@describetag`` nodes in the Elixir AST. Comments and string literals do not
count. Lane membership is the ``srcs`` attribute of the evaluated Bazel query
for the two DB targets (``web_ng_lane_target_query``), not the BUILD text.
"""

import os
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path

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

LANE_TAGS = ("db_free", "web_ng_shared_fixture_db", "topology_atlas_db")
LANE_TAG_SET = set(LANE_TAGS)
LANE_ATTRIBUTES = {"moduletag", "tag", "describetag"}
NETWORKS_TARGET = "//elixir/web-ng:networks_live_db_test"
TOPOLOGY_TARGET = "//elixir/web-ng:topology_atlas_db_test"
WEB_NG_LABEL = "//elixir/web-ng:"

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


def test_files():
    return sorted(
        str(path.relative_to(WEB_NG))
        for path in (WEB_NG / "test").rglob("*_test.exs")
    )


def lane_tags_in(source):
    return lane_tags_in_source((WEB_NG / source).read_text())


def lane_tags_in_source(source):
    """Lane atoms on @moduletag, @tag, and @describetag in the Elixir AST."""
    tags = set()
    tokens = _tokenize(source)
    index = 0
    while index < len(tokens):
        if (
            tokens[index][0] == "at"
            and index + 1 < len(tokens)
            and tokens[index + 1][0] == "ident"
            and tokens[index + 1][1] in LANE_ATTRIBUTES
        ):
            tag = _lane_tag_at(tokens, index + 2)
            if tag:
                tags.add(tag)
        index += 1
    return tags


def _lane_tag_at(tokens, index):
    if index < len(tokens) and tokens[index] == ("op", "("):
        index += 1
    if index >= len(tokens):
        return None
    kind, value = tokens[index]
    if kind == "atom" and value in LANE_TAG_SET:
        return value
    if kind == "ident" and value in LANE_TAG_SET and _keyword_enables(tokens, index):
        return value
    return None


def _keyword_enables(tokens, index):
    if index + 1 >= len(tokens) or tokens[index + 1][0] != "colon":
        return False
    if index + 2 >= len(tokens):
        return True
    return tokens[index + 2] not in {("ident", "false"), ("atom", "false")}


def evaluated_lane_srcs(query_path):
    """Map each DB lane target to the test sources Bazel put in its srcs."""
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


def _tokenize(source):
    tokens = []
    _scan(source, 0, len(source), tokens)
    return tokens


def _scan(source, start, end, tokens):
    index = start
    while index < end:
        char = source[index]
        if char in " \t\r\n,":
            index += 1
            continue
        if char == "#":
            newline = source.find("\n", index, end)
            index = end if newline < 0 else newline + 1
            continue
        if char == "@":
            tokens.append(("at", "@"))
            index += 1
            continue
        if char == ":":
            index = _scan_colon(source, index, end, tokens)
            continue
        if char == '"':
            index = _scan_string(source, index, end, tokens)
            continue
        if char == "'":
            index = _scan_charlist(source, index, end, tokens)
            continue
        if char == "~" and index + 1 < end and (source[index + 1].isalpha() or source[index + 1] in "\"'([{</|"):
            index = _scan_sigil(source, index, end, tokens)
            continue
        if char == "?" and index + 1 < end and source[index + 1] not in " \t\r\n":
            index = _skip_char_literal(source, index, end)
            continue
        if char.isalpha() or char == "_":
            index = _scan_ident(source, index, end, tokens)
            continue
        tokens.append(("op", char))
        index += 1
    return index


def _scan_colon(source, index, end, tokens):
    nxt = index + 1
    if nxt < end and source[nxt] == '"':
        atom_end = _skip_quoted(source, nxt, end, '"', interpolate=False)
        tokens.append(("atom", source[nxt + 1:atom_end - 1]))
        return atom_end
    if nxt < end and (source[nxt].isalpha() or source[nxt] == "_"):
        cursor = nxt + 1
        while cursor < end and (source[cursor].isalnum() or source[cursor] in "_@!?") and source[cursor] not in "!?":
            cursor += 1
        if cursor < end and source[cursor] in "!?":
            cursor += 1
        tokens.append(("atom", source[nxt:cursor]))
        return cursor
    tokens.append(("colon", ":"))
    return nxt


def _scan_ident(source, index, end, tokens):
    cursor = index + 1
    while cursor < end and (source[cursor].isalnum() or source[cursor] == "_"):
        cursor += 1
    if cursor < end and source[cursor] in "!?":
        cursor += 1
    tokens.append(("ident", source[index:cursor]))
    return cursor


def _scan_string(source, index, end, tokens):
    if source.startswith('"""', index):
        return _scan_delimited(source, index + 3, end, '"""', interpolate=True, tokens=tokens)
    return _scan_delimited(source, index + 1, end, '"', interpolate=True, tokens=tokens)


def _scan_charlist(source, index, end, tokens):
    if source.startswith("'''", index):
        return _scan_delimited(source, index + 3, end, "'''", interpolate=True, tokens=tokens)
    return _scan_delimited(source, index + 1, end, "'", interpolate=True, tokens=tokens)


def _scan_delimited(source, index, end, closer, interpolate, tokens):
    while index < end:
        if source.startswith(closer, index):
            return index + len(closer)
        if source[index] == "\\":
            index += 2
            continue
        if interpolate and source.startswith("#{", index):
            index = _scan_braces(source, index + 2, end, tokens)
            continue
        index += 1
    return index


def _scan_braces(source, index, end, tokens):
    depth = 1
    while index < end and depth:
        char = source[index]
        if char == "#":
            newline = source.find("\n", index, end)
            index = end if newline < 0 else newline + 1
            continue
        if char == '"':
            index = _scan_string(source, index, end, tokens)
            continue
        if char == "'":
            index = _scan_charlist(source, index, end, tokens)
            continue
        if char == "~" and index + 1 < end and (source[index + 1].isalpha() or source[index + 1] in "\"'([{</|"):
            index = _scan_sigil(source, index, end, tokens)
            continue
        if char == "{":
            depth += 1
            index += 1
            continue
        if char == "}":
            depth -= 1
            index += 1
            continue
        if char == "@":
            tokens.append(("at", "@"))
            index += 1
            continue
        if char == ":":
            index = _scan_colon(source, index, end, tokens)
            continue
        if char.isalpha() or char == "_":
            index = _scan_ident(source, index, end, tokens)
            continue
        if char in " \t\r\n,":
            index += 1
            continue
        tokens.append(("op", char))
        index += 1
    return index


def _scan_sigil(source, index, end, tokens):
    cursor = index + 1
    while cursor < end and source[cursor].isalpha():
        cursor += 1
    if cursor >= end:
        tokens.append(("sigil", ""))
        return cursor
    name = source[index + 1:cursor]
    interpolate = not name or name[0].islower()
    opener = source[cursor]
    pairs = {"(": ")", "[": "]", "{": "}", "<": ">"}
    if opener in pairs:
        return _scan_nested(source, cursor + 1, end, opener, pairs[opener], interpolate, tokens)
    if opener == '"':
        if source.startswith('"""', cursor):
            return _scan_delimited(source, cursor + 3, end, '"""', interpolate, tokens)
        return _scan_delimited(source, cursor + 1, end, '"', interpolate, tokens)
    if opener == "'":
        if source.startswith("'''", cursor):
            return _scan_delimited(source, cursor + 3, end, "'''", interpolate, tokens)
        return _scan_delimited(source, cursor + 1, end, "'", interpolate, tokens)
    return _scan_delimited(source, cursor + 1, end, opener, interpolate, tokens)


def _scan_nested(source, index, end, opener, closer, interpolate, tokens):
    depth = 1
    while index < end and depth:
        if source[index] == "\\":
            index += 2
            continue
        if interpolate and source.startswith("#{", index):
            index = _scan_braces(source, index + 2, end, tokens)
            continue
        if source[index] == opener:
            depth += 1
        elif source[index] == closer:
            depth -= 1
        index += 1
    return index


def _skip_quoted(source, index, end, quote, interpolate):
    return _scan_delimited(source, index + 1, end, quote, interpolate, tokens=[])


def _skip_char_literal(source, index, end):
    cursor = index + 1
    if cursor < end and source[cursor] == "\\":
        return min(end, cursor + 2)
    return min(end, cursor + 1)


class WebNgLaneRoutingParseTest(unittest.TestCase):
    def test_lane_tags_come_from_attribute_ast_not_text(self):
        ignored = '''
        defmodule ExampleTest do
          # @moduletag :db_free
          @moduledoc """
          prose mentions @tag :db_free
          """
          @moduletag :web_ng_shared_fixture_db
          @moduletag db_free: false
          test "string" do
            assert "@describetag :db_free" == "nope"
            _ = ~s"""
            @moduletag :db_free
            """
          end
          describe "group" do
            @describetag :topology_atlas_db
            test "kept" do
              :ok
            end
          end
        end
        '''
        self.assertEqual(
            lane_tags_in_source(ignored),
            {"web_ng_shared_fixture_db", "topology_atlas_db"},
        )
        self.assertEqual(lane_tags_in_source("@tag(:db_free)\n"), {"db_free"})

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


class WebNgTestLaneRoutingContractTest(unittest.TestCase):
    def setUp(self):
        self.files = test_files()
        srcs = evaluated_lane_srcs(LANE_QUERY)
        self.networks_srcs = srcs[NETWORKS_TARGET]
        self.topology_srcs = srcs[TOPOLOGY_TARGET]

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
