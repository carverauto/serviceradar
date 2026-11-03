defmodule ServiceRadar.NetworkDiscovery.MapperGraphIngestionTest do
  use ServiceRadar.DataCase, async: false

  alias Ecto.Adapters.SQL
  alias ServiceRadar.NetworkDiscovery.MapperResultsIngestor
  alias ServiceRadar.NetworkDiscovery.TopologyGraph.Links
  alias ServiceRadar.Repo
  alias ServiceRadar.TestSupport

  @moduletag :integration

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    clear_report_fingerprints()
    on_exit(&clear_report_fingerprints/0)
    Application.put_env(:serviceradar_core, :mapper_topology_edge_stale_minutes, 180)

    :ok
  end

  # Regression coverage for the 2026-06-25 evidence-pipeline outage: records
  # that legitimately lack logical-key fields (SNMP-L2 ARP+FDB attachments,
  # UniFi wireless clients / uplinks, wireguard-derived links) were rejected by
  # Required validation because Ash's :string defaults cast the ingestor's ""
  # sentinel back to nil, and one rejected record aborted the whole payload.
  # These payload shapes mirror what go/pkg/mapper actually emits
  # (snmp_l2_query.go, ubnt_topology.go, and the core wireguard deriver).
  test "ingest_topology persists SNMP-L2 ARP+FDB attachment records without a neighbor port id" do
    now = DateTime.truncate(DateTime.utc_now(), :microsecond)
    purge_topology_rows(["sr:it-fdb-switch"])

    payload = [
      %{
        "timestamp" => now,
        "protocol" => "SNMP-L2",
        "agent_id" => "agent-it-fdb",
        "gateway_id" => "agent-it-fdb",
        "partition" => "default",
        "local_device_id" => "sr:it-fdb-switch",
        "local_device_ip" => "192.0.2.10",
        "local_if_index" => 4,
        "neighbor_chassis_id" => "aa:bb:cc:dd:fd:11",
        "neighbor_mgmt_addr" => "192.0.2.77",
        "metadata" => %{
          "protocol" => "SNMP-L2",
          "source" => "snmp-arp-fdb",
          "evidence" => "ipNetToMedia+dot1dTpFdb",
          "fdb_port_mapped" => "true",
          "evidence_class" => "inferred-segment",
          "relation_family" => "ATTACHED_TO",
          "confidence_tier" => "medium",
          "confidence_reason" => "arp_fdb_port_mapping"
        }
      }
    ]

    assert :ok = MapperResultsIngestor.ingest_topology(Jason.encode!(payload), %{})

    rows = topology_rows("sr:it-fdb-switch")
    assert [row] = rows
    assert row["protocol"] == "SNMP-L2"
    assert row["neighbor_chassis_id"] == "aa:bb:cc:dd:fd:11"
    assert row["neighbor_port_id"] == ""
  end

  test "ingest_topology persists UniFi wireless client association records" do
    now = DateTime.truncate(DateTime.utc_now(), :microsecond)
    purge_topology_rows(["sr:it-unifi-ap"])

    payload = [
      %{
        "timestamp" => now,
        "protocol" => "UniFi-API",
        "agent_id" => "agent-it-unifi",
        "gateway_id" => "agent-it-unifi",
        "partition" => "default",
        "local_device_id" => "sr:it-unifi-ap",
        "local_device_ip" => "192.0.2.20",
        "local_if_name" => "wireless",
        "neighbor_chassis_id" => "aa:bb:cc:dd:fd:22",
        "neighbor_system_name" => "laptop-01",
        "neighbor_mgmt_addr" => "192.0.2.88",
        "metadata" => %{
          "source" => "unifi-api-wireless-client",
          "evidence_class" => "endpoint-attachment",
          "relation_type" => "ATTACHED_TO",
          "relation_family" => "ATTACHED_TO",
          "confidence_tier" => "high",
          "confidence_reason" => "controller_client_association",
          "client_type" => "wireless",
          "uplink_device_id" => "unifi-sr:dev-1"
        }
      }
    ]

    assert :ok = MapperResultsIngestor.ingest_topology(Jason.encode!(payload), %{})

    assert [row] = topology_rows("sr:it-unifi-ap")
    assert row["protocol"] == "UniFi-API"
    assert row["neighbor_port_id"] == ""
    assert row["neighbor_system_name"] == "laptop-01"
  end

  test "ingest_topology persists UniFi uplink records without a neighbor port id" do
    now = DateTime.truncate(DateTime.utc_now(), :microsecond)
    purge_topology_rows(["sr:it-unifi-switch"])

    payload = [
      %{
        "timestamp" => now,
        "protocol" => "UniFi-API",
        "agent_id" => "agent-it-unifi",
        "gateway_id" => "agent-it-unifi",
        "partition" => "default",
        "local_device_id" => "sr:it-unifi-switch",
        "local_device_ip" => "192.0.2.30",
        "local_if_index" => 24,
        "local_if_name" => "Port 24",
        "neighbor_chassis_id" => "aa:bb:cc:dd:fd:33",
        "neighbor_system_name" => "office-ap",
        "neighbor_mgmt_addr" => "192.0.2.31",
        "metadata" => %{
          "source" => "unifi-api-uplink",
          "evidence_class" => "direct-physical",
          "relation_family" => "CONNECTS_TO",
          "uplink_device_id" => "unifi-sr:dev-2",
          "uplink_device_name" => "office-switch"
        }
      }
    ]

    assert :ok = MapperResultsIngestor.ingest_topology(Jason.encode!(payload), %{})

    assert [row] = topology_rows("sr:it-unifi-switch")
    assert row["protocol"] == "UniFi-API"
    assert row["neighbor_port_id"] == ""
    assert row["local_if_index"] == 24
  end

  test "ingest_topology persists wireguard-derived records without a neighbor chassis id" do
    now = DateTime.truncate(DateTime.utc_now(), :microsecond)
    purge_topology_rows(["sr:it-wg-router-a"])

    payload = [
      %{
        "timestamp" => now,
        "protocol" => "wireguard-derived",
        "agent_id" => "agent-it-wg",
        "gateway_id" => "agent-it-wg",
        "partition" => "default",
        "local_device_id" => "sr:it-wg-router-a",
        "local_device_ip" => "203.0.113.1",
        "local_if_name" => "wg0",
        "neighbor_device_id" => "sr:it-wg-router-b",
        "neighbor_port_id" => "wg0",
        "neighbor_port_descr" => "wireguard",
        "neighbor_system_name" => "wg-router-b",
        "neighbor_mgmt_addr" => "203.0.113.2",
        "metadata" => %{
          "source" => "wireguard-derived",
          "evidence_class" => "direct-logical",
          "relation_family" => "LOGICAL_PEER",
          "rule" => "exact_wg_interface_name_two_router_endpoints",
          "tunnel_name" => "wg0",
          "confidence_tier" => "high",
          "confidence_score" => 95,
          "confidence_reason" => "deterministic_wireguard_tunnel_match"
        }
      }
    ]

    assert :ok = MapperResultsIngestor.ingest_topology(Jason.encode!(payload), %{})

    assert [row] = topology_rows("sr:it-wg-router-a")
    assert row["protocol"] == "wireguard-derived"
    assert row["neighbor_chassis_id"] == ""
    assert row["neighbor_port_id"] == "wg0"
  end

  # Pre-fix, this exact mix froze the whole pipeline: the sparse FDB/wireless
  # records failed Required validation, handle_bulk_result mapped the partial
  # success to {:error, _}, and even the fully-valid LLDP record never reached
  # TopologyGraph.upsert_links/1. Post-fix every record in the mix persists.
  test "ingest_topology with mixed sparse and rich records persists all of them" do
    now = DateTime.truncate(DateTime.utc_now(), :microsecond)
    purge_topology_rows(["sr:it-mix-a", "sr:it-mix-sw"])

    payload = [
      %{
        "timestamp" => now,
        "protocol" => "LLDP",
        "agent_id" => "agent-it-mix",
        "gateway_id" => "agent-it-mix",
        "partition" => "default",
        "local_device_id" => "sr:it-mix-a",
        "local_device_ip" => "198.51.100.1",
        "local_if_index" => 10,
        "local_if_name" => "eth0",
        "neighbor_device_id" => "sr:it-mix-b",
        "neighbor_port_id" => "Gi0/1",
        "neighbor_system_name" => "mix-b",
        "neighbor_mgmt_addr" => "198.51.100.2",
        "metadata" => %{"source" => "lldp"}
      },
      %{
        "timestamp" => now,
        "protocol" => "SNMP-L2",
        "agent_id" => "agent-it-mix",
        "gateway_id" => "agent-it-mix",
        "partition" => "default",
        "local_device_id" => "sr:it-mix-sw",
        "local_device_ip" => "198.51.100.3",
        "local_if_index" => 7,
        "neighbor_chassis_id" => "aa:bb:cc:dd:fd:44",
        "neighbor_mgmt_addr" => "198.51.100.99",
        "metadata" => %{
          "source" => "snmp-arp-fdb",
          "evidence" => "ipNetToMedia+dot1dTpFdb",
          "fdb_port_mapped" => "true",
          "evidence_class" => "inferred-segment",
          "relation_family" => "ATTACHED_TO",
          "confidence_tier" => "medium",
          "confidence_reason" => "arp_fdb_port_mapping"
        }
      },
      %{
        "timestamp" => now,
        "protocol" => "UniFi-API",
        "agent_id" => "agent-it-mix",
        "gateway_id" => "agent-it-mix",
        "partition" => "default",
        "local_device_id" => "sr:it-mix-a",
        "local_device_ip" => "198.51.100.1",
        "local_if_name" => "wireless",
        "neighbor_chassis_id" => "aa:bb:cc:dd:fd:55",
        "neighbor_system_name" => "phone-01",
        "neighbor_mgmt_addr" => "198.51.100.88",
        "metadata" => %{
          "source" => "unifi-api-wireless-client",
          "evidence_class" => "endpoint-attachment",
          "relation_family" => "ATTACHED_TO",
          "confidence_tier" => "high",
          "confidence_reason" => "controller_client_association"
        }
      }
    ]

    assert :ok = MapperResultsIngestor.ingest_topology(Jason.encode!(payload), %{})

    lldp_rows = topology_rows("sr:it-mix-a")
    assert Enum.any?(lldp_rows, &(&1["protocol"] == "LLDP" and &1["neighbor_port_id"] == "Gi0/1"))
    assert Enum.any?(lldp_rows, &(&1["protocol"] == "UniFi-API" and &1["neighbor_port_id"] == ""))

    assert [fdb_row] = topology_rows("sr:it-mix-sw")
    assert fdb_row["neighbor_port_id"] == ""
  end

  defp purge_topology_rows(local_device_ids) when is_list(local_device_ids) do
    SQL.query!(
      Repo,
      "DELETE FROM platform.mapper_topology_links WHERE local_device_id = ANY($1)",
      [local_device_ids]
    )

    :ok
  end

  defp topology_rows(local_device_id) do
    %Postgrex.Result{rows: rows, columns: columns} =
      SQL.query!(
        Repo,
        """
        SELECT protocol, local_device_id, local_if_index, neighbor_device_id,
               neighbor_chassis_id, neighbor_port_id, neighbor_system_name
        FROM platform.mapper_topology_links
        WHERE local_device_id = $1
        """,
        [local_device_id]
      )

    Enum.map(rows, fn row -> columns |> Enum.zip(row) |> Map.new() end)
  end

  defp clear_report_fingerprints do
    Enum.each(:persistent_term.get(), fn
      {{Links, :report_fingerprint, _scope} = key, _value} ->
        :persistent_term.erase(key)

      _other ->
        :ok
    end)

    :ok
  end
end
