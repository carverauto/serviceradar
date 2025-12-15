defmodule ServiceRadarWebNGWeb.DashboardEngineTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNGWeb.Dashboard.Engine
  alias ServiceRadarWebNGWeb.Dashboard.Plugins

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

    [panel] = Engine.build_panels(response)
    assert panel.plugin == Plugins.Timeseries
    assert is_map(panel.assigns)
    assert panel.assigns.spec[:x] == "timestamp"
  end

  test "selects topology plugin when graph payload includes nodes and edges" do
    response = %{
      "results" => [%{"nodes" => [%{"id" => "n1", "label" => "Node"}], "edges" => []}],
      "viz" => %{"columns" => [%{"name" => "result", "type" => "jsonb"}]}
    }

    [panel] = Engine.build_panels(response)
    assert panel.plugin == Plugins.Topology
  end

  test "falls back to table plugin when no other plugin matches" do
    response = %{"results" => [%{"a" => 1}], "viz" => %{"suggestions" => [%{"kind" => "table"}]}}
    [panel] = Engine.build_panels(response)
    assert panel.plugin == Plugins.Table
  end
end
