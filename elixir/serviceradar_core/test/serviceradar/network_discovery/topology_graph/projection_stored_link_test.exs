defmodule ServiceRadar.NetworkDiscovery.TopologyGraph.ProjectionStoredLinkTest do
  @moduledoc """
  Unit coverage (no database): a link read back from
  `platform.mapper_topology_links` carries the NOT NULL logical-key sentinels
  the ingestor writes for missing values (`local_if_index` 0, `""` for
  protocol, neighbor port id and chassis id). It must project exactly as the
  record the mapper reported before those sentinels were applied.
  """

  use ExUnit.Case, async: true

  alias ServiceRadar.NetworkDiscovery.TopologyGraph.Projection

  defp reported_wireguard_link do
    %{
      timestamp: ~U[2026-11-03 12:00:00Z],
      protocol: nil,
      local_device_id: "sr:router-a",
      local_device_ip: "192.0.2.1",
      local_if_index: nil,
      local_if_name: "wg0",
      neighbor_device_id: "sr:router-b",
      neighbor_chassis_id: nil,
      neighbor_port_id: nil,
      neighbor_port_descr: "wireguard",
      neighbor_system_name: "router-b",
      neighbor_mgmt_addr: "192.0.2.2",
      metadata: %{
        "source" => "wireguard-derived",
        "confidence_tier" => "high",
        "confidence_reason" => "deterministic_wireguard_tunnel_match"
      }
    }
  end

  defp stored(link) do
    %{
      link
      | protocol: "",
        local_if_index: 0,
        neighbor_chassis_id: "",
        neighbor_port_id: ""
    }
  end

  test "a stored link projects as the reported link it came from" do
    reported = reported_wireguard_link()

    assert Projection.projection_payload(stored(reported)) ==
             Projection.projection_payload(reported)
  end

  test "a stored ifIndex of 0 is no interface index" do
    payload = Projection.projection_payload(stored(reported_wireguard_link()))

    assert payload.local_if_index == nil
    assert payload.local_interface_id == "sr:router-a/wg0"
    assert payload.protocol == "unknown"
  end

  test "a stored link with neither interface name nor index uses the unknown-local interface" do
    link = %{stored(reported_wireguard_link()) | local_if_name: nil}

    assert Projection.projection_payload(link).local_interface_id == "sr:router-a/unknown-local"
  end
end
