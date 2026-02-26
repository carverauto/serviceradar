defmodule ServiceRadarWebNG.Topology.RuntimeGraphTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNG.Topology.RuntimeGraph
  alias ServiceRadarWebNG.Topology.Native

  test "topology_links_query/0 reads canonical backend relation" do
    query = RuntimeGraph.topology_links_query()

    assert query =~ "MATCH (a:Device)-[r:CANONICAL_TOPOLOGY]->(b:Device)"
    assert query =~ "a.id STARTS WITH 'sr:'"
    assert query =~ "b.id STARTS WITH 'sr:'"
    assert query =~ "coalesce(r.relation_type, type(r)) IN ['CONNECTS_TO', 'ATTACHED_TO']"
    assert query =~ "ORDER BY"
  end

  test "topology_links_query/0 supports backend rollback mode via mapper interface evidence query" do
    original = Application.get_env(:serviceradar_web_ng, :god_view_backend_authoritative_topology)

    Application.put_env(:serviceradar_web_ng, :god_view_backend_authoritative_topology, false)

    on_exit(fn ->
      if is_nil(original) do
        Application.delete_env(:serviceradar_web_ng, :god_view_backend_authoritative_topology)
      else
        Application.put_env(
          :serviceradar_web_ng,
          :god_view_backend_authoritative_topology,
          original
        )
      end
    end)

    query = RuntimeGraph.topology_links_query()

    assert query =~ "MATCH (ai:Interface)-[r]->(bi:Interface)"
    assert query =~ "r.ingestor = 'mapper_topology_v1'"
    assert query =~ "type(r) IN ['CONNECTS_TO', 'INFERRED_TO', 'ATTACHED_TO', 'OBSERVED_TO']"
  end

  test "topology_links_query/0 returns relation metadata and interface attribution" do
    query = RuntimeGraph.topology_links_query()

    assert query =~ "relation_type: coalesce(r.relation_type, type(r))"
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
    assert query =~ "telemetry_source: coalesce(r.telemetry_source, 'none')"
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
    assert link.telemetry_source == "interface"
  end
end
