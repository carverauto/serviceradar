defmodule ServiceRadarWebNG.Topology.RuntimeGraphTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNG.Topology.RuntimeGraph
  alias ServiceRadarWebNG.Topology.Native

  test "topology_links_query/0 reads canonical backend relation" do
    query = RuntimeGraph.topology_links_query()

    assert query =~ "MATCH (a:Device)-[r:CANONICAL_TOPOLOGY]->(b:Device)"
    assert query =~ "coalesce(r.relation_type, type(r)) IN ['CONNECTS_TO', 'ATTACHED_TO']"
    assert query =~ "ORDER BY"
  end

  test "topology_links_query/0 returns relation metadata and interface attribution" do
    query = RuntimeGraph.topology_links_query()

    assert query =~ "relation_type: coalesce(r.relation_type, type(r))"
    assert query =~ "local_if_name: coalesce(r.local_if_name, '')"
    assert query =~ "local_if_index: r.local_if_index"
    assert query =~ "neighbor_if_name: coalesce(r.neighbor_if_name, '')"
    assert query =~ "neighbor_if_index: r.neighbor_if_index"
    assert query =~ "flow_pps: coalesce(r.flow_pps, 0)"
    assert query =~ "flow_bps_ab: coalesce(r.flow_bps_ab, 0)"
    assert query =~ "telemetry_source: coalesce(r.telemetry_source, 'none')"
  end

  test "runtime graph ingest/get preserves neighbor interface attribution and telemetry" do
    graph = Native.runtime_graph_new()

    rows = [
      %{
        local_device_id: "sr:a",
        local_device_ip: "192.0.2.1",
        local_if_name: "eth0",
        local_if_index: 7,
        neighbor_if_name: "eth1",
        neighbor_if_index: 22,
        neighbor_device_id: "sr:b",
        neighbor_mgmt_addr: "192.0.2.2",
        neighbor_system_name: "device-b",
        flow_pps: 1000,
        flow_bps: 8_000_000,
        capacity_bps: 1_000_000_000,
        flow_pps_ab: 700,
        flow_pps_ba: 300,
        flow_bps_ab: 5_600_000,
        flow_bps_ba: 2_400_000,
        telemetry_source: "interface",
        telemetry_observed_at: "2026-02-25T00:00:00Z",
        protocol: "LLDP",
        confidence_tier: "high",
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
    assert link.neighbor_if_index == 22
    assert link.local_if_name == "eth0"
    assert link.neighbor_if_name == "eth1"
    assert link.flow_pps == 1000
    assert link.flow_bps == 8_000_000
    assert link.flow_pps_ab == 700
    assert link.flow_pps_ba == 300
    assert link.flow_bps_ab == 5_600_000
    assert link.flow_bps_ba == 2_400_000
    assert link.telemetry_source == "interface"
  end
end
