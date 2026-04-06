defmodule ServiceRadarWebNG.Topology.RuntimeGraphTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNG.Topology.Native
  alias ServiceRadarWebNG.Topology.RuntimeGraph

  test "topology_links_query/0 reads canonical backend relation" do
    query = RuntimeGraph.topology_links_query()

    assert query =~ "MATCH (a:Device)-[r:CANONICAL_TOPOLOGY]->(b:Device)"
    assert query =~ "a.id STARTS WITH 'sr:'"
    assert query =~ "b.id STARTS WITH 'sr:'"
    assert query =~ "toUpper(coalesce(r.relation_type, '')) IN ['CONNECTS_TO', 'ATTACHED_TO']"
    assert query =~ "r.relation_type IS NULL"
    assert query =~ "toLower(coalesce(r.evidence_class, '')) IN ['direct', 'endpoint-attachment']"
    assert query =~ "END AS topology_plane"
    assert query =~ "END AS topology_plane_priority"
    refute query =~ "toUpper(coalesce(r.relation_type, '')) = 'INFERRED_TO'"
    assert query =~ "ORDER BY"
  end

  test "topology_links_query/0 stays canonical-only even if legacy flag is set false" do
    original = Application.get_env(:serviceradar_web_ng, :god_view_backend_authoritative_topology)

    try do
      Application.put_env(:serviceradar_web_ng, :god_view_backend_authoritative_topology, false)
      query = RuntimeGraph.topology_links_query()
      assert query =~ "MATCH (a:Device)-[r:CANONICAL_TOPOLOGY]->(b:Device)"
      refute query =~ "MATCH (ai:Interface)-[r]->(bi:Interface)"
    after
      if is_nil(original) do
        Application.delete_env(:serviceradar_web_ng, :god_view_backend_authoritative_topology)
      else
        Application.put_env(
          :serviceradar_web_ng,
          :god_view_backend_authoritative_topology,
          original
        )
      end
    end
  end

  test "topology_links_query/0 returns relation metadata and interface attribution" do
    query = RuntimeGraph.topology_links_query()

    assert query =~ "relation_type: coalesce(r.relation_type, type(r))"
    assert query =~ "topology_plane: topology_plane"
    assert query =~ "local_if_name: coalesce(r.local_if_name, '')"
    assert query =~ "local_if_index: r.local_if_index"
    assert query =~ "local_if_name_ab: coalesce(r.local_if_name_ab, r.local_if_name, '')"
    assert query =~ "local_if_index_ab: coalesce(r.local_if_index_ab, r.local_if_index)"
    assert query =~ "local_if_name_ba: coalesce(r.local_if_name_ba, r.neighbor_if_name, '')"
    assert query =~ "local_if_index_ba: coalesce(r.local_if_index_ba, r.neighbor_if_index)"
    assert query =~ "neighbor_if_name: coalesce(r.neighbor_if_name, '')"
    assert query =~ "neighbor_if_index: r.neighbor_if_index"
    assert query =~ "confidence_reason: coalesce(r.confidence_reason, '')"
    assert query =~ "flow_pps_ab: coalesce(r.flow_pps_ab, 0)"
    assert query =~ "flow_bps_ab: coalesce(r.flow_bps_ab, 0)"
    assert query =~ "telemetry_eligible: coalesce("
    assert query =~ "telemetry_source: coalesce(r.telemetry_source, 'none')"
    assert query =~ "topology_plane_priority ASC"
  end

  test "runtime graph ingest/get preserves neighbor interface attribution" do
    graph = Native.runtime_graph_new()

    rows = [
      %{
        local_device_id: "sr:a",
        local_device_ip: "192.0.2.1",
        local_if_name: "eth0",
        local_if_index: 7,
        local_if_name_ab: "eth0.100",
        local_if_index_ab: 107,
        local_if_name_ba: "eth1.200",
        local_if_index_ba: 222,
        neighbor_if_name: "eth1",
        neighbor_if_index: 22,
        neighbor_device_id: "sr:b",
        neighbor_mgmt_addr: "192.0.2.2",
        neighbor_system_name: "device-b",
        protocol: "LLDP",
        confidence_tier: "high",
        confidence_reason: "direct_lldp_neighbor",
        flow_pps: 42,
        flow_bps: 4_200,
        capacity_bps: 1_000_000_000,
        flow_pps_ab: 30,
        flow_pps_ba: 12,
        flow_bps_ab: 3_000,
        flow_bps_ba: 1_200,
        telemetry_source: "interface",
        telemetry_observed_at: "2026-02-25T10:00:00Z",
        metadata: %{
          source: "mapper_topology_v1",
          inference: "direct_lldp_neighbor",
          confidence_tier: "high",
          confidence_score: 95.0
        }
      }
    ]

    assert 1 == Native.runtime_graph_ingest_rows(graph, rows)

    [link] = Native.runtime_graph_get_links(graph)
    assert link.local_if_index == 7
    assert link.local_if_index_ab == 107
    assert link.local_if_name_ab == "eth0.100"
    assert link.local_if_index_ba == 222
    assert link.local_if_name_ba == "eth1.200"
    assert link.neighbor_if_index == 22
    assert link.local_if_name == "eth0"
    assert link.neighbor_if_name == "eth1"
    assert link.confidence_reason == "direct_lldp_neighbor"
    assert link.flow_pps == 42
    assert link.flow_bps == 4_200
    assert link.capacity_bps == 1_000_000_000
    assert link.flow_pps_ab == 30
    assert link.flow_pps_ba == 12
    assert link.flow_bps_ab == 3_000
    assert link.flow_bps_ba == 1_200
    assert link.telemetry_eligible == true
    assert link.telemetry_source == "interface"
  end

  test "canonical_runtime_row?/1 accepts canonical direct rows and rejects inferred/non-canonical rows" do
    assert RuntimeGraph.canonical_runtime_row?(%{
             local_device_id: "sr:a",
             neighbor_device_id: "sr:b",
             evidence_class: "direct",
             metadata: %{"relation_type" => "CONNECTS_TO"}
           })

    refute RuntimeGraph.canonical_runtime_row?(%{
             local_device_id: "sr:a",
             neighbor_device_id: "sr:b",
             evidence_class: "inferred",
             metadata: %{"relation_type" => "INFERRED_TO"}
           })

    refute RuntimeGraph.canonical_runtime_row?(%{
             local_device_id: "ip-192.168.1.1",
             neighbor_device_id: "sr:b",
             evidence_class: "direct",
             metadata: %{"relation_type" => "CONNECTS_TO"}
           })
  end

  test "runtime row classifiers distinguish backbone from attachment rows" do
    backbone_row = %{
      local_device_id: "sr:a",
      neighbor_device_id: "sr:b",
      evidence_class: "direct",
      metadata: %{"relation_type" => "CONNECTS_TO"}
    }

    attachment_row = %{
      local_device_id: "sr:a",
      neighbor_device_id: "sr:endpoint-b",
      evidence_class: "endpoint-attachment",
      metadata: %{"relation_type" => "ATTACHED_TO"}
    }

    inferred_row = %{
      local_device_id: "sr:a",
      neighbor_device_id: "sr:b",
      evidence_class: "inferred",
      metadata: %{"relation_type" => "INFERRED_TO"}
    }

    assert RuntimeGraph.backbone_runtime_row?(backbone_row)
    refute RuntimeGraph.attachment_runtime_row?(backbone_row)

    assert RuntimeGraph.attachment_runtime_row?(attachment_row)
    refute RuntimeGraph.backbone_runtime_row?(attachment_row)

    refute RuntimeGraph.backbone_runtime_row?(inferred_row)
    refute RuntimeGraph.attachment_runtime_row?(inferred_row)
  end

  test "prioritize_runtime_rows/1 keeps backbone rows first and bounds attachment rows" do
    backbone_rows =
      Enum.map(1..5_010, fn idx ->
        %{
          local_device_id: "sr:backbone-#{idx}",
          neighbor_device_id: "sr:backbone-peer-#{idx}",
          evidence_class: "direct",
          metadata: %{"relation_type" => "CONNECTS_TO"}
        }
      end)

    attachment_rows =
      Enum.map(1..2_010, fn idx ->
        %{
          local_device_id: "sr:attachment-#{idx}",
          neighbor_device_id: "sr:endpoint-#{idx}",
          evidence_class: "endpoint-attachment",
          metadata: %{"relation_type" => "ATTACHED_TO"}
        }
      end)

    prioritized = RuntimeGraph.prioritize_runtime_rows(backbone_rows ++ attachment_rows)

    assert length(prioritized) == 7_000
    assert Enum.count(prioritized, &RuntimeGraph.backbone_runtime_row?/1) == 5_000
    assert Enum.count(prioritized, &RuntimeGraph.attachment_runtime_row?/1) == 2_000

    assert Enum.take(prioritized, 3) == Enum.take(backbone_rows, 3)
    assert Enum.at(prioritized, 4_999) == Enum.at(backbone_rows, 4_999)
    assert Enum.at(prioritized, 5_000) == hd(attachment_rows)
  end
end
