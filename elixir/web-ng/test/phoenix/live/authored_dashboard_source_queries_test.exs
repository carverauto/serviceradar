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

  describe "panel_attrs_from_output/4 gauge bindings" do
    test "uses grouped availability bindings for gauge outputs" do
      attrs =
        SourceQueries.panel_attrs_from_output(
          %{id: "dashboard-1", panels: []},
          %{
            id: "source-1",
            name: "Device availability",
            srql_query: "in:devices stats:count() as count by is_available",
            fields: [
              %{"name" => "is_available", "type" => "boolean"},
              %{"name" => "count", "type" => "number"}
            ]
          },
          "gauge",
          %{"lookback_days" => "30"}
        )

      assert attrs.data_binding["value_field"] == "count"
      assert attrs.data_binding["label_field"] == "is_available"
      refute Map.has_key?(attrs.data_binding, "denominator_field")
    end
  end

  describe "outputs_for_preview/1" do
    test "summarizes grouped availability outputs from the returned schema" do
      outputs =
        SourceQueries.outputs_for_preview(%{
          fields: [
            %{"name" => "is_available", "type" => "boolean"},
            %{"name" => "count", "type" => "number"}
          ],
          compatible_visuals: [:availability, :gauge]
        })

      assert Enum.map(outputs, & &1["summary"]) == [
               "Count grouped by is available",
               "Count grouped by is available"
             ]
    end

    test "summarizes pivot bindings from row, column, and value fields" do
      [output] =
        SourceQueries.outputs_for_preview(%{
          fields: [
            %{"name" => "site", "type" => "string"},
            %{"name" => "is_available", "type" => "boolean"},
            %{"name" => "count", "type" => "number"}
          ],
          compatible_visuals: [:pivot]
        })

      assert output["summary"] == "Rows: site | Columns: is available | Values: sum count"
    end
  end

  describe "templates/0" do
    test "includes target-group availability templates backed by supported SRQL filters" do
      template_queries = Map.new(SourceQueries.templates(), &{&1.key, &1.query})

      assert template_queries["armis_development_availability"] ==
               ~s|in:devices metadata.armis_tags:%development% stats:"count() as count by is_available"|

      assert template_queries["armis_testing_availability"] ==
               ~s|in:devices metadata.armis_tags:%testing% stats:"count() as count by is_available"|

      assert template_queries["hypervisor_availability"] ==
               ~s|in:devices type:Hypervisor stats:"count() as count by is_available"|

      assert template_queries["workstation_availability"] ==
               ~s|in:devices type:Workstation stats:"count() as count by is_available"|

      assert template_queries["router_switch_availability"] ==
               ~s|in:devices type:(Router,Switch) stats:"count() as count by is_available"|
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
