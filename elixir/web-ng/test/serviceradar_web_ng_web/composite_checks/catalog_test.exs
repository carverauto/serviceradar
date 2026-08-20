defmodule ServiceRadarWebNGWeb.CompositeChecks.CatalogTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNGWeb.CompositeChecks.Catalog

  describe "filter_query/2" do
    test "builds the form the translator's composite filter accepts" do
      assert Catalog.filter_query("dmz-isolation", "not_isolated") ==
               "in:devices composite.dmz-isolation:not_isolated"
    end
  end

  describe "filtered_slug/1" do
    test "finds the check a query filters on" do
      assert Catalog.filtered_slug("in:devices composite.dmz-isolation:not_isolated") ==
               "dmz-isolation"
    end

    test "finds it among other filters" do
      query = "in:devices source:armis composite.dmz-isolation:isolated_verified tag:managed"

      assert Catalog.filtered_slug(query) == "dmz-isolation"
    end

    test "ignores a status filter, which names no verdict to show" do
      # `composite.<slug>.status` narrows by status, not verdict. A verdict
      # column driven by it would claim a verdict the query never asked for.
      #
      # This also pins the backtracking trap: a lookahead alone let the greedy
      # slug shrink to `dmz-` to escape `(?!\.status)`, yielding a slug that
      # does not exist.
      assert Catalog.filtered_slug("in:devices composite.dmz-isolation.status:down") == nil
      assert Catalog.filtered_slug("in:devices composite.a-b-c.status:down") == nil
    end

    test "a status filter does not hide a real verdict filter elsewhere" do
      query = "in:devices composite.other.status:down composite.dmz-isolation:not_isolated"

      assert Catalog.filtered_slug(query) == "dmz-isolation"
    end

    test "returns nil for a query with no composite filter" do
      assert Catalog.filtered_slug("in:devices source:armis") == nil
      assert Catalog.filtered_slug("") == nil
      assert Catalog.filtered_slug(nil) == nil
    end

    test "normalizes case, matching the translator's field handling" do
      assert Catalog.filtered_slug("in:devices COMPOSITE.DMZ-Isolation:x") == "dmz-isolation"
    end

    test "does not match a bare composite prefix" do
      assert Catalog.filtered_slug("in:devices composite:something") == nil
    end
  end
end
