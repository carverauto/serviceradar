defmodule ServiceRadarWebNGWeb.DashboardEngineTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias Phoenix.LiveView.Socket
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

  test "threads SRQL metric units into timeseries panel spec" do
    response = %{
      "results" => [
        %{
          "timestamp" => "2025-01-01T00:00:00Z",
          "series" => "disk",
          "value" => 1024.0,
          "metric" => %{"unit" => "By"}
        },
        %{
          "timestamp" => "2025-01-01T00:01:00Z",
          "series" => "network",
          "value" => 1000.0,
          "metric.unit" => "b/s"
        }
      ],
      "viz" => %{
        "suggestions" => [
          %{"kind" => "timeseries", "x" => "timestamp", "y" => "value", "series" => "series"}
        ]
      }
    }

    panels = Engine.build_panels(response)

    timeseries_panel = Enum.find(panels, &(&1.plugin == Plugins.Timeseries))
    assert timeseries_panel.assigns.spec[:series_units] == %{"disk" => :bytes, "network" => :bits_per_sec}
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
    response = %{
      "results" => Enum.map(1..501, &%{"count" => &1, "bytes_total" => &1 * 1024}),
      "schema" => %{"columns" => ["bytes_total", "count"]}
    }

    panels = Engine.build_panels(response)
    assert %{plugin: Plugins.Table, assigns: assigns} = Enum.find(panels, &(&1.plugin == Plugins.Table))
    assert assigns.columns == ["bytes_total", "count"]
    assert length(assigns.results) == 500
    assert length(assigns.source_results) == 501
    assert assigns.total_count == 501
    assert assigns.truncated
  end

  test "table plugin keeps blank values last when sorting descending" do
    response = %{
      "results" => [
        %{"name" => "blank", "count" => ""},
        %{"name" => "high", "count" => 10},
        %{"name" => "low", "count" => 2},
        %{"name" => "nil", "count" => nil}
      ],
      "schema" => %{"columns" => ["name", "count"]}
    }

    panels = Engine.build_panels(response)
    assert %{plugin: Plugins.Table, assigns: assigns} = Enum.find(panels, &(&1.plugin == Plugins.Table))

    socket = %Socket{
      assigns: Map.merge(assigns, %{__changed__: %{}, sort_col: "count", sort_dir: :asc})
    }

    assert {:noreply, sorted_socket} = Plugins.Table.handle_event("sort", %{"col" => "count"}, socket)

    assert Enum.map(sorted_socket.assigns.results, & &1["name"]) == ["high", "low", "blank", "nil"]
    assert sorted_socket.assigns.sort_dir == :desc
  end

  test "table plugin defaults omitted timezone to UTC" do
    socket = %Socket{assigns: %{__changed__: %{}}}

    assert {:ok, updated_socket} = Plugins.Table.update(%{panel_assigns: %{}}, socket)
    assert updated_socket.assigns.timezone == "Etc/UTC"

    assert {:ok, updated_socket} =
             Plugins.Table.update(%{panel_assigns: %{timezone: nil}}, socket)

    assert updated_socket.assigns.timezone == "Etc/UTC"

    assert {:ok, updated_socket} =
             Plugins.Table.update(%{panel_assigns: %{timezone: false}}, socket)

    assert updated_socket.assigns.timezone == false
  end
end
