defmodule ServiceRadarWebNG.Topology.GodViewStreamConversionTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNG.Topology.GodViewStream

  @moduletag :db_free

  test "edge_connected_node_ids/1 only returns normalized edge-connected ids" do
    assert GodViewStream.edge_connected_node_ids([" farm01 ", "uswagg", nil, "farm01", ""]) == [
             "farm01",
             "uswagg"
           ]
  end

  test "edge_topology_class_counts/1 buckets edges by topology class" do
    edges = [
      %{evidence_class: "direct"},
      %{evidence_class: "direct-physical"},
      %{evidence_class: "logical"},
      %{evidence_class: "hosted"},
      %{evidence_class: "hosted-virtual"},
      %{evidence_class: "inferred"},
      %{evidence_class: "inferred-segment"},
      %{evidence_class: "endpoint-attachment"},
      %{metadata: %{"evidence_class" => "endpoint-attachment"}},
      %{evidence_class: "observed"},
      %{evidence_class: nil},
      :not_a_map
    ]

    assert GodViewStream.edge_topology_class_counts(edges) == %{
             # direct, direct-physical, logical, unknown(nil)
             backbone: 4,
             attachment: 2,
             inferred: 2,
             hosted: 2,
             observed: 1
           }
  end

  test "edge_topology_class_counts/1 returns zeroed counts for empty or invalid input" do
    empty = %{backbone: 0, attachment: 0, inferred: 0, hosted: 0, observed: 0}

    assert GodViewStream.edge_topology_class_counts([]) == empty
    assert GodViewStream.edge_topology_class_counts(nil) == empty
  end
end
