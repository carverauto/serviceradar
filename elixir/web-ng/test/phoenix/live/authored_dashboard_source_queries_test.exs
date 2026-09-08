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

  describe "panel_attrs_from_output/4 capacity forecast bindings" do
    test "auto-enables forecast overlay for capacity forecast sources" do
      attrs =
        SourceQueries.panel_attrs_from_output(
          %{id: "dashboard-1", panels: []},
          %{
            id: "source-forecast",
            name: "Capacity forecasts",
            srql_query: "in:capacity_forecasts status:projected sort:forecasted_at:desc limit:100",
            fields: capacity_forecast_fields()
          },
          "line",
          %{}
        )

      assert attrs.data_binding["time_field"] == "forecasted_at"
      assert attrs.data_binding["value_field"] == "projected_value"
      assert attrs.data_binding["label_field"] == "resource_label"
      assert attrs.display_config["capacity_forecast"] == true
    end
  end

  describe "outputs_for_preview/1" do
    test "labels table outputs as detail rows" do
      [output] =
        SourceQueries.outputs_for_preview(%{
          fields: [%{"name" => "name", "type" => "string"}],
          compatible_visuals: [:table]
        })

      assert output["label"] == "Detail rows"
      assert output["intent"] == "detail_rows"
    end

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
    test "ships curated starter templates" do
      template_queries = Map.new(SourceQueries.generic_templates(), &{&1.key, &1.query})

      assert template_queries["device_availability"] ==
               "in:devices stats:count() as count by is_available limit:25"

      assert template_queries["device_type_count"] ==
               "in:devices stats:count() as count by type limit:25"

      assert template_queries["capacity_forecasts"] ==
               "in:capacity_forecasts status:projected sort:forecasted_at:desc limit:100"

      refute Map.has_key?(template_queries, "armis_development_availability")
      refute Map.has_key?(template_queries, "router_switch_availability")
    end
  end

  describe "source_queries/1" do
    test "reads only the current stored source shape and counts linked panels" do
      source = %{
        "id" => "src_one",
        "name" => "Current source",
        "srql_query" => "in:devices limit:10",
        "fields" => [],
        "sample_rows" => [],
        "compatible_visuals" => ["table"],
        "outputs" => [],
        "updated_at" => "2026-05-26T00:00:00Z"
      }

      legacy_source = %{id: "legacy", name: "Legacy", srql_query: "in:services"}

      dashboard = %{
        metadata: %{"source_queries" => [source, legacy_source]},
        panels: [
          %{metadata: %{"source_query_id" => "src_one"}},
          %{metadata: %{"source_query_id" => "other"}}
        ]
      }

      assert [
               %{
                 id: "src_one",
                 name: "Current source",
                 srql_query: "in:devices limit:10",
                 panel_count: 1
               }
             ] = SourceQueries.source_queries(dashboard)
    end
  end

  describe "field options" do
    test "does not expose a blank Auto option" do
      assert SourceQueries.field_options([%{"name" => "count", "type" => "number"}]) == [
               {"Count (number)", "count"}
             ]
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

  defp capacity_forecast_fields do
    [
      %{"name" => "forecasted_at", "type" => "datetime"},
      %{"name" => "resource_key", "type" => "string"},
      %{"name" => "resource_label", "type" => "string"},
      %{"name" => "metric_name", "type" => "string"},
      %{"name" => "horizon_ends_at", "type" => "datetime"},
      %{"name" => "current_value", "type" => "number"},
      %{"name" => "projected_value", "type" => "number"},
      %{"name" => "lower_bound", "type" => "number"},
      %{"name" => "upper_bound", "type" => "number"},
      %{"name" => "projected_exhaustion_at", "type" => "datetime"}
    ]
  end
end
