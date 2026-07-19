defmodule ServiceRadar.PrefixTags.ManualTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.PrefixTags.Manual

  describe "parse_tags_input/1" do
    test "splits on commas, whitespace, and newlines" do
      assert Manual.parse_tags_input("site:hq, role:wifi\nzone:dmz  tenant:acme") == [
               "site:hq",
               "role:wifi",
               "zone:dmz",
               "tenant:acme"
             ]
    end

    test "dedupes and drops blanks" do
      assert Manual.parse_tags_input(["site:hq", " site:hq ", "", "role:wifi"]) == [
               "site:hq",
               "role:wifi"
             ]
    end

    test "nil and unknown return empty" do
      assert Manual.parse_tags_input(nil) == []
      assert Manual.parse_tags_input(123) == []
    end
  end

  test "source_name is manual" do
    assert Manual.source_name() == "manual"
  end
end
