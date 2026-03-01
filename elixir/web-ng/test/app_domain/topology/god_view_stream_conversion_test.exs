defmodule ServiceRadarWebNG.Topology.GodViewStreamConversionTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNG.Topology.GodViewStream

  test "edge_connected_node_ids/1 only returns normalized edge-connected ids" do
    assert GodViewStream.edge_connected_node_ids([" farm01 ", "uswagg", nil, "farm01", ""]) == [
             "farm01",
             "uswagg"
           ]
  end
end
