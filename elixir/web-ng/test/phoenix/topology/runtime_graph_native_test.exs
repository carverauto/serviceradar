defmodule ServiceRadarWebNG.Topology.RuntimeGraphNativeTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNG.Topology.Native

  test "runtime graph ingest preserves backend directional telemetry fields" do
    graph_ref = Native.runtime_graph_new()

    row = %{
      local_device_id: "sr:device-a",
      local_device_ip: "192.168.1.10",
      local_if_name: "eth0",
      local_if_index: 10,
      local_if_name_ab: "eth0.10",
      local_if_index_ab: 110,
      local_if_name_ba: "eth1.20",
      local_if_index_ba: 220,
      neighbor_if_name: "eth1",
      neighbor_if_index: 20,
      neighbor_device_id: "sr:device-b",
      neighbor_mgmt_addr: "192.168.1.11",
      neighbor_system_name: "device-b",
      protocol: "lldp",
      evidence_class: "direct",
      confidence_tier: "high",
      confidence_reason: "direct_lldp_neighbor",
      flow_pps: 300,
      flow_bps: 3_000,
      capacity_bps: 1_000_000_000,
      flow_pps_ab: 120,
      flow_pps_ba: 180,
      flow_bps_ab: 1_200,
      flow_bps_ba: 1_800,
      telemetry_source: "interface",
      telemetry_observed_at: "2026-02-26T00:45:06Z",
      metadata: %{
        source: "mapper",
        inference: "direct_lldp_neighbor",
        confidence_tier: "high",
        confidence_score: 95.0
      }
    }

    assert 1 == Native.runtime_graph_ingest_rows(graph_ref, [row])
    [stored] = Native.runtime_graph_get_links(graph_ref)

    assert stored.flow_pps == 300
    assert stored.flow_bps == 3_000
    assert stored.capacity_bps == 1_000_000_000
    assert stored.flow_pps_ab == 120
    assert stored.flow_pps_ba == 180
    assert stored.flow_bps_ab == 1_200
    assert stored.flow_bps_ba == 1_800
    assert stored.local_if_index_ab == 110
    assert stored.local_if_name_ab == "eth0.10"
    assert stored.local_if_index_ba == 220
    assert stored.local_if_name_ba == "eth1.20"
    assert stored.confidence_reason == "direct_lldp_neighbor"
    assert stored.telemetry_source == "interface"
    assert stored.evidence_class == "direct"
  end
end
