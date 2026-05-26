defmodule ServiceRadarWebNGWeb.AuthoredDashboardSourceQueriesTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNGWeb.AuthoredDashboardLive.SourceQueries

  describe "panel_attrs_from_output/4 trend queries" do
    test "replaces only top-level time tokens" do
      attrs =
        panel_attrs(
          ~s|in:logs message:"time:last_1h inside string" time:last_24h sort:timestamp:desc|,
          "14"
        )

      assert attrs.visual_config["trend_query"] ==
               ~s|in:logs message:"time:last_1h inside string" time:last_14d sort:timestamp:desc|
    end

    test "handles leading time tokens" do
      attrs = panel_attrs("time:last_1h in:services rollup_stats:availability", "7")

      assert attrs.visual_config["trend_query"] ==
               "time:last_7d in:services rollup_stats:availability"
    end

    test "adds a comparison time token when the source query has none" do
      attrs = panel_attrs("in:devices stats:count() as count by is_available", "30")

      assert attrs.visual_config["trend_query"] ==
               "in:devices stats:count() as count by is_available time:last_30d"
    end
  end

  defp panel_attrs(query, lookback_days) do
    SourceQueries.panel_attrs_from_output(
      %{id: "dashboard-1", panels: []},
      %{
        id: "source-1",
        name: "Device availability",
        srql_query: query,
        fields: [
          %{"name" => "is_available", "type" => "boolean"},
          %{"name" => "count", "type" => "number"}
        ]
      },
      "availability",
      %{"lookback_days" => lookback_days}
    )
  end
end
