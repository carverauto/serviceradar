defmodule ServiceRadar.SRQLTargetQueryTest do
  @moduledoc """
  The rule every stored target query is held to. Readers act on a target
  query's whole selection, so a token that bounds or reshapes the result would
  be silently ignored there; it is refused when the query is saved instead.
  """

  use ExUnit.Case, async: true

  alias ServiceRadar.SRQLTargetQuery

  describe "result controls" do
    test "refuses each token that bounds or reshapes the result, naming it" do
      for {query, named} <- [
            {"in:devices hostname:host01* limit:50", "limit:50"},
            {~s|in:devices stats:"count() as total"|, "stats:"},
            {"in:devices rollup_stats:availability", "rollup_stats:availability"},
            {"in:devices bucket:5m", "bucket:"},
            {"in:devices downsample:1h agg:max", "bucket:"},
            {~s|in:devices stats:"count() as total" by vendor_name other:true limit:5|,
             "other:true"}
          ] do
        assert {:error, message} = SRQLTargetQuery.validate(query), query
        assert message =~ named, query
        assert message =~ "cannot be used in a target query", query
      end
    end

    test "accepts sort, time and filters, returning the query with its entity explicit" do
      for {query, normalized} <- [
            {"hostname:host01* sort:hostname:asc",
             "in:devices hostname:host01* sort:hostname:asc"},
            {"in:devices order:last_seen:desc time:last_24h",
             "in:devices order:last_seen:desc time:last_24h"},
            {"in:devices is_managed:true", "in:devices is_managed:true"}
          ] do
        assert SRQLTargetQuery.validate(query) == {:ok, normalized}
      end
    end
  end

  describe "entity" do
    test "prefixes the default target and refuses a query naming another entity" do
      assert SRQLTargetQuery.validate("hostname:agent01*",
               default_target: :agents,
               entity: :agents
             ) ==
               {:ok, "in:agents hostname:agent01*"}

      assert {:error, message} =
               SRQLTargetQuery.validate("in:interfaces type:ethernet", entity: :devices)

      assert message =~ "must target devices (in:devices), not interfaces"
    end
  end
end
