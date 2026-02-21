defmodule ServiceRadarWebNGWeb.DashboardTopologyPluginTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNGWeb.Dashboard.Plugins.Topology

  test "supports? detects graph payloads" do
    assert Topology.supports?(%{"results" => [%{"nodes" => [], "edges" => []}]})
    refute Topology.supports?(%{"results" => [%{"a" => 1}]})
  end

  test "build merges nodes and edges across rows and normalizes ids" do
    response = %{
      "results" => [
        %{
          "nodes" => [%{"device_id" => "dev-1", "hostname" => "device-1"}],
          "edges" => [%{"source" => "dev-1", "target" => "dev-2", "type" => "links_to"}]
        },
        %{
          "nodes" => [%{"id" => "dev-2", "label" => "device-2"}],
          "edges" => []
        }
      ]
    }

    assert {:ok, assigns} = Topology.build(response)
    assert length(assigns.nodes) == 2
    assert Enum.any?(assigns.nodes, &(&1.id == "dev-1"))
    assert Enum.any?(assigns.nodes, &(&1.id == "dev-2"))
    assert [%{source: "dev-1", target: "dev-2"}] = assigns.edges
  end
end
