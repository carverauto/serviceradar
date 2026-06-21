defmodule ServiceRadarWebNGWeb.DashboardEngineTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias ServiceRadarWebNGWeb.Dashboard.Engine
  alias ServiceRadarWebNGWeb.Dashboard.Plugins

  @moduletag :db_free

  test "selects timeseries plugin when SRQL viz suggests timeseries" do
    response = %{
      "results" => [
        %{"timestamp" => "2025-01-01T00:00:00Z", "series" => "cpu", "value" => 1.0},
        %{"timestamp" => "2025-01-01T00:01:00Z", "series" => "cpu", "value" => 2.0}
      ],
      "viz" => %{
        "suggestions" => [
          %{"kind" => "timeseries", "x" => "timestamp", "y" => "value", "series" => "series"}
        ]
      }
    }

    panels = Engine.build_panels(response)
    assert Enum.any?(panels, &(&1.plugin == Plugins.Timeseries))
    assert Enum.any?(panels, &(&1.plugin == Plugins.Table))

    timeseries_panel = Enum.find(panels, &(&1.plugin == Plugins.Timeseries))
    assert is_map(timeseries_panel.assigns)
    assert timeseries_panel.assigns.spec[:x] == "timestamp"
  end

  test "selects topology plugin when graph payload includes nodes and edges" do
    response = %{
      "results" => [%{"nodes" => [%{"id" => "n1", "label" => "Node"}], "edges" => []}],
      "viz" => %{"columns" => [%{"name" => "result", "type" => "jsonb"}]}
    }

    panels = Engine.build_panels(response)
    assert Enum.any?(panels, &(&1.plugin == Plugins.Topology))
    assert Enum.any?(panels, &(&1.plugin == Plugins.Table))
  end

  test "falls back to table plugin when no other plugin matches" do
    response = %{"results" => [%{"a" => 1}], "viz" => %{"suggestions" => [%{"kind" => "table"}]}}
    assert [%{plugin: Plugins.Table}] = Engine.build_panels(response)
  end

  test "table plugin preserves schema columns and caps rendered rows" do
    rows =
      for idx <- 1..525 do
        %{"service" => "svc-#{idx}", "count" => idx, "status" => "ok"}
      end

    response = %{
      "results" => rows,
      "viz" => %{
        "columns" => [
          %{"name" => "service"},
          %{"name" => "status"},
          %{"name" => "count"}
        ],
        "suggestions" => [%{"kind" => "table"}]
      }
    }

    panels = Engine.build_panels(response)
    assert %{plugin: Plugins.Table, assigns: assigns} = Enum.find(panels, &(&1.plugin == Plugins.Table))
    assert assigns.columns == ["service", "status", "count"]
    assert assigns.result_count == 525
    assert assigns.capped?
    assert length(assigns.results) == 500
    assert length(assigns.page_rows) == 50
    assert assigns.page == 1
    assert assigns.page_count == 10

    html =
      render_component(&Plugins.Table.render/1, Map.merge(assigns, %{id: "capped", myself: "capped"}))

    refute html =~ ~s(phx-click="table_sort")
    assert html =~ "sorting disabled"
  end
end
