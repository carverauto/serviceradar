defmodule ServiceRadarWebNG.Topology.GodViewStreamConversionTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNG.Topology.GodViewStream
  alias ServiceRadarWebNG.Topology.Native
  alias ServiceRadarWebNG.Topology.RuntimeGraph

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

  test "inferred-segment filtering preserves the only bridge between direct components" do
    edges = [
      converted_edge("a", "b", "direct"),
      converted_edge("c", "d", "direct"),
      converted_edge("b", "c", "inferred-segment")
    ]

    assert edges
           |> GodViewStream.connectivity_preserving_inferred_segment_edges(%{})
           |> edge_pairs() == ["a::b", "b::c", "c::d"]
  end

  test "inferred-segment filtering deterministically drops a redundant component bridge" do
    edges = [
      converted_edge("a", "b", "direct"),
      converted_edge("c", "d", "direct"),
      converted_edge("b", "c", "inferred-segment"),
      converted_edge("a", "d", "inferred-segment")
    ]

    forward = GodViewStream.connectivity_preserving_inferred_segment_edges(edges, %{})
    reversed = GodViewStream.connectivity_preserving_inferred_segment_edges(Enum.reverse(edges), %{})

    assert edge_pairs(forward) == ["a::b", "a::d", "c::d"]
    assert edge_pairs(reversed) == edge_pairs(forward)
  end

  test "runtime edge pipeline preserves pre-filter provenance in 4 to 3 diagnostics" do
    raw_edges = [
      converted_edge("a", "b", "direct"),
      converted_edge("c", "d", "direct"),
      converted_edge("a", "b", "inferred-segment"),
      converted_edge("b", "c", "inferred-segment")
    ]

    pipeline = GodViewStream.prepare_runtime_edge_pipeline(raw_edges, %{})
    stats = GodViewStream.runtime_edge_pipeline_stats(pipeline, [], 0)

    assert pipeline.raw_edges == raw_edges
    assert edge_pairs(pipeline.final_edges) == ["a::b", "b::c", "c::d"]

    assert stats.raw_links == 4
    assert stats.unique_pairs == 3
    assert stats.final_edges == 3
    assert stats.edge_parity_delta == 1
    assert stats.raw_direct == 2
    assert stats.raw_inferred == 2
    assert stats.raw_attachment == 0
    assert stats.final_inferred == 1
  end

  test "native ingest and replace round-trip preserves an inferred-segment bridge provenance" do
    graph = Native.runtime_graph_new()

    rows = [
      runtime_link("sr:a", "sr:b", "direct", "CONNECTS_TO"),
      runtime_link("sr:c", "sr:d", "direct", "CONNECTS_TO"),
      runtime_link("sr:b", "sr:c", "inferred-segment", "ATTACHED_TO")
    ]

    assert Native.runtime_graph_ingest_rows(graph, rows) == 3

    native_links = Native.runtime_graph_get_links(graph)
    inferred_native = Enum.find(native_links, &(&1.local_device_id == "sr:b"))

    assert %{
             "evidence_class" => "inferred-segment",
             "relation_type" => "ATTACHED_TO"
           } = Jason.decode!(inferred_native.metadata_json)

    assert Native.runtime_graph_replace_links(graph, native_links) == true

    replaced_links = Native.runtime_graph_get_links(graph)
    replaced_inferred = Enum.find(replaced_links, &(&1.local_device_id == "sr:b"))

    assert %{
             "evidence_class" => "inferred-segment",
             "relation_type" => "ATTACHED_TO"
           } = Jason.decode!(replaced_inferred.metadata_json)

    pipeline =
      replaced_links
      |> RuntimeGraph.decode_runtime_rows()
      |> GodViewStream.runtime_links_to_edges()
      |> GodViewStream.prepare_runtime_edge_pipeline(%{})

    assert edge_pairs(pipeline.final_edges) == ["sr:a::sr:b", "sr:b::sr:c", "sr:c::sr:d"]

    bridge = Enum.find(pipeline.final_edges, &(&1.source == "sr:b" and &1.target == "sr:c"))
    assert bridge.evidence_class == "inferred"
    assert bridge.metadata["relation_type"] == "INFERRED_TO"
    assert bridge.metadata["topology_plane"] == "backbone"
    assert bridge.metadata["raw_relation_type"] == "ATTACHED_TO"
    assert bridge.metadata["raw_evidence_class"] == "inferred-segment"
    assert bridge.metadata["connectivity_forest_bridge"] == true
  end

  test "rendered pipeline stats recompute parity for a 3 to 1 attachment collapse" do
    attachments = [
      converted_edge("anchor", "endpoint-a", "endpoint-attachment"),
      converted_edge("anchor", "endpoint-b", "endpoint-attachment"),
      converted_edge("anchor", "endpoint-c", "endpoint-attachment")
    ]

    stats =
      GodViewStream.runtime_edge_pipeline_stats(
        %{raw_edges: attachments, pair_edges: attachments, final_edges: attachments},
        [],
        0
      )

    [rendered_edge | _] = attachments
    rendered = GodViewStream.rendered_pipeline_stats(stats, [], [rendered_edge])

    assert stats.edge_parity_delta == 0
    assert rendered.final_edges == 1
    assert rendered.edge_parity_delta == 2
  end

  test "inferred-segment filtering ignores explicit attachment paths when preserving connectivity" do
    edges = [
      converted_edge("a", "endpoint", "endpoint-attachment"),
      converted_edge("b", "endpoint", "endpoint-attachment"),
      converted_edge("a", "b", "inferred-segment")
    ]

    filtered = GodViewStream.connectivity_preserving_inferred_segment_edges(edges, %{})

    assert edge_pairs(filtered) == ["a::b", "a::endpoint", "b::endpoint"]
  end

  test "inferred-segment filtering ignores direct UniFi single-identifier attachment candidates" do
    devices = %{
      "a" => %{type_id: 9, ip: "192.0.2.10"},
      "b" => %{type_id: 9, ip: "192.0.2.11"},
      "endpoint" => %{type_id: 2, ip: "192.0.2.12"}
    }

    single_identifier = fn source ->
      converted_edge(source, "endpoint", "direct", %{
        protocol: "unifi-api",
        confidence_reason: "single_identifier_inference"
      })
    end

    edges = [
      single_identifier.("a"),
      single_identifier.("b"),
      converted_edge("a", "b", "inferred-segment")
    ]

    filtered = GodViewStream.connectivity_preserving_inferred_segment_edges(edges, devices)

    assert edge_pairs(filtered) == ["a::b", "a::endpoint", "b::endpoint"]
  end

  test "attachment collapse cannot displace a selected inferred bridge in the same group" do
    devices = %{
      "a" => %{type_id: 9, ip: "192.0.2.10"},
      "b" => %{type_id: 9, ip: "192.0.2.11"},
      "c" => %{type_id: 9, ip: "192.0.2.12"}
    }

    inferred = converted_edge("a", "b", "inferred-segment", %{confidence_tier: "medium"})

    stronger_attachment =
      converted_edge("c", "b", "endpoint-attachment", %{confidence_tier: "high"})

    edges =
      [inferred, stronger_attachment]
      |> GodViewStream.connectivity_preserving_inferred_segment_edges(devices)
      |> GodViewStream.collapse_endpoint_attachments_preserving_inferred_segments(devices)

    assert edge_pairs(edges) == ["a::b", "b::c"]

    bridge = Enum.find(edges, &(&1.source == "a" and &1.target == "b"))
    assert bridge.evidence_class == "inferred"
    assert bridge.metadata["relation_type"] == "INFERRED_TO"
    assert bridge.metadata["topology_plane"] == "backbone"
    assert bridge.metadata["raw_relation_type"] == "ATTACHED_TO"
    assert bridge.metadata["raw_evidence_class"] == "inferred-segment"
    assert bridge.metadata["connectivity_forest_bridge"] == true
  end

  test "edge details serialize normalized bridge semantics and raw provenance" do
    bridge = %{
      source: "a",
      target: "b",
      evidence_class: "inferred",
      metadata: %{
        "relation_type" => "INFERRED_TO",
        "evidence_class" => "inferred",
        "topology_plane" => "backbone",
        "raw_relation_type" => "ATTACHED_TO",
        "raw_evidence_class" => "inferred-segment",
        "connectivity_forest_bridge" => true
      }
    }

    assert %{
             metadata: %{
               relation_type: "INFERRED_TO",
               topology_plane: "backbone",
               raw_relation_type: "ATTACHED_TO",
               raw_evidence_class: "inferred-segment",
               connectivity_forest_bridge: true
             }
           } = GodViewStream.edge_details_json(bridge)
  end

  test "inferred-segment filtering totally orders otherwise identical candidates" do
    alpha =
      "a"
      |> converted_edge("d", "inferred-segment")
      |> put_in([:metadata, "selection_marker"], "alpha")

    zulu =
      "a"
      |> converted_edge("d", "inferred-segment")
      |> put_in([:metadata, "selection_marker"], "zulu")

    direct = [converted_edge("a", "b", "direct"), converted_edge("c", "d", "direct")]

    forward =
      GodViewStream.connectivity_preserving_inferred_segment_edges(direct ++ [zulu, alpha], %{})

    reversed =
      GodViewStream.connectivity_preserving_inferred_segment_edges(direct ++ [alpha, zulu], %{})

    assert inferred_selection_markers(forward) == inferred_selection_markers(reversed)
    assert length(inferred_selection_markers(forward)) == 1
  end

  # Every other test in this file passes an EMPTY device map, which is why this shipped: with no
  # devices, both sides of an attachment look like endpoints, the structural check cannot fire,
  # and the connectivity forest quietly swallowed real endpoint attachments. A fleet whose only
  # endpoint evidence is inferred-segment (ARP/FDB) therefore produced no clusters at all, and
  # its access switches lost every edge, because their only links were to endpoints.
  test "ARP/FDB endpoint attachments are not consumed by the connectivity forest" do
    edges = [
      converted_edge("sw-a", "sw-b", "direct"),
      converted_edge("sw-a", "ep-1", "inferred-segment"),
      converted_edge("sw-a", "ep-2", "inferred-segment"),
      converted_edge("sw-a", "ep-3", "inferred-segment")
    ]

    devices = %{
      "sw-a" => %{type: "switch", ip: "192.168.1.2"},
      "sw-b" => %{type: "switch", ip: "192.168.1.3"},
      "ep-1" => %{type: "workstation", ip: "192.168.1.51"},
      "ep-2" => %{type: "workstation", ip: "192.168.1.52"},
      "ep-3" => %{type: "workstation", ip: "192.168.1.53"}
    }

    pipeline = GodViewStream.prepare_runtime_edge_pipeline(edges, devices)

    attachments =
      Enum.filter(pipeline.final_edges, &(&1.evidence_class == "endpoint-attachment"))

    assert length(attachments) == 3,
           "expected three endpoint attachments, got #{inspect(Enum.map(pipeline.final_edges, & &1.evidence_class))}"

    for edge <- attachments do
      assert edge.metadata["relation_type"] == "ATTACHED_TO"
      refute edge.metadata["connectivity_forest_bridge"]
    end

    # The genuine device-to-device backbone link is untouched.
    assert Enum.any?(pipeline.final_edges, &(&1.source == "sw-a" and &1.target == "sw-b"))
  end

  # The other half of the contract: a device-to-device inferred segment still IS forest glue.
  test "a device-to-device inferred segment is still normalized into a forest bridge" do
    edges = [
      converted_edge("sw-a", "sw-b", "direct"),
      converted_edge("sw-c", "sw-d", "direct"),
      converted_edge("sw-b", "sw-c", "inferred-segment")
    ]

    devices = %{
      "sw-a" => %{type: "switch", ip: "192.168.1.2"},
      "sw-b" => %{type: "switch", ip: "192.168.1.3"},
      "sw-c" => %{type: "switch", ip: "192.168.1.4"},
      "sw-d" => %{type: "switch", ip: "192.168.1.5"}
    }

    pipeline = GodViewStream.prepare_runtime_edge_pipeline(edges, devices)
    bridge = Enum.find(pipeline.final_edges, &(&1.source == "sw-b" and &1.target == "sw-c"))

    assert bridge.evidence_class == "inferred"
    assert bridge.metadata["relation_type"] == "INFERRED_TO"
    assert bridge.metadata["connectivity_forest_bridge"] == true
  end

  # An access switch learns one host per bridge port, and clusters are keyed on
  # (anchor, port). Eight hosts on eight ports produced eight groups of ONE and cleared the
  # 3-member minimum on none of them, so a switch full of servers rendered as a bare dot.
  describe "endpoint cluster port coalescing" do
    defp port_group(anchor, if_index, endpoint_ids) do
      %{
        cluster_id:
          if(is_integer(if_index),
            do: "cluster:endpoints:#{anchor}:ifindex:#{if_index}",
            else: "cluster:endpoints:#{anchor}"
          ),
        anchor_id: anchor,
        anchor_if_index: if_index,
        anchor_if_name: if(is_integer(if_index), do: "port#{if_index}"),
        endpoint_ids: endpoint_ids,
        source_endpoint_ids: endpoint_ids,
        target_endpoint_ids: [],
        source_identity_endpoint_ids: endpoint_ids,
        target_identity_endpoint_ids: [],
        edges: Enum.map(endpoint_ids, &%{id: "att:#{&1}"})
      }
    end

    test "one host per port on an access switch coalesces into a single anchor group" do
      groups =
        for index <- 1..8, do: port_group("sw-access", index, ["ep-#{index}"])

      assert [merged] = GodViewStream.coalesce_subquorum_anchor_groups(groups)
      assert merged.anchor_id == "sw-access"
      assert merged.cluster_id == "cluster:endpoints:sw-access"
      assert length(merged.endpoint_ids) == 8
      # A merged group spans ports and must not claim one.
      assert merged.anchor_if_index == nil
      assert merged.anchor_if_name == nil
      assert length(merged.edges) == 8
    end

    test "a port that already reaches quorum keeps its per-port identity" do
      quorate = port_group("sw-mixed", 10, ["a", "b", "c"])
      singles = for index <- 1..2, do: port_group("sw-mixed", index, ["ep-#{index}"])

      result = GodViewStream.coalesce_subquorum_anchor_groups([quorate | singles])
      by_id = Map.new(result, &{&1.cluster_id, &1})

      # The downstream-switch-on-one-port cluster is deliberate and survives untouched.
      assert by_id["cluster:endpoints:sw-mixed:ifindex:10"].anchor_if_index == 10
      assert by_id["cluster:endpoints:sw-mixed:ifindex:10"].endpoint_ids == ["a", "b", "c"]
      # The two sub-quorum ports fold together.
      assert length(by_id["cluster:endpoints:sw-mixed"].endpoint_ids) == 2
    end

    test "an anchor with a single sub-quorum port is left exactly as it was" do
      only = port_group("sw-quiet", 3, ["lonely"])
      assert GodViewStream.coalesce_subquorum_anchor_groups([only]) == [only]
    end

    test "groups from different anchors never merge with each other" do
      groups = [port_group("sw-a", 1, ["a1"]), port_group("sw-b", 1, ["b1"])]
      result = GodViewStream.coalesce_subquorum_anchor_groups(groups)

      assert result |> Enum.map(& &1.anchor_id) |> Enum.sort() == ["sw-a", "sw-b"]
      assert Enum.all?(result, &(length(&1.endpoint_ids) == 1))
    end
  end

  defp converted_edge(source, target, raw_evidence_class, attrs \\ %{}) do
    relation_type = if raw_evidence_class == "direct", do: "CONNECTS_TO", else: "ATTACHED_TO"
    evidence_class = if raw_evidence_class == "inferred-segment", do: "endpoint-attachment", else: raw_evidence_class

    topology_plane =
      if raw_evidence_class in ["inferred-segment", "endpoint-attachment"],
        do: "attachment",
        else: "backbone"

    Map.merge(
      %{
        source: source,
        target: target,
        protocol: if(raw_evidence_class == "direct", do: "lldp", else: "snmp-l2"),
        evidence_class: evidence_class,
        confidence_reason: if(raw_evidence_class == "inferred-segment", do: "arp_fdb_port_mapping", else: "direct"),
        metadata: %{
          "relation_type" => relation_type,
          "evidence_class" => raw_evidence_class,
          "topology_plane" => topology_plane
        }
      },
      attrs
    )
  end

  defp runtime_link(source, target, evidence_class, relation_type) do
    %{
      local_device_id: source,
      neighbor_device_id: target,
      protocol: "test",
      evidence_class: evidence_class,
      confidence_tier: "medium",
      confidence_reason: "regression",
      metadata: %{
        "relation_type" => relation_type,
        "evidence_class" => evidence_class,
        "topology_plane" => if(relation_type == "CONNECTS_TO", do: "backbone", else: "attachment")
      }
    }
  end

  defp edge_pairs(edges) do
    edges
    |> Enum.map(fn edge ->
      [left, right] = Enum.sort([edge.source, edge.target])
      "#{left}::#{right}"
    end)
    |> Enum.sort()
  end

  defp inferred_selection_markers(edges) do
    edges
    |> Enum.filter(&(get_in(&1, [:metadata, "evidence_class"]) == "inferred-segment"))
    |> Enum.map(&get_in(&1, [:metadata, "selection_marker"]))
  end
end
