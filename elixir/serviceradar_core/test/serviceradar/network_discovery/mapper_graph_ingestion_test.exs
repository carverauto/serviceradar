defmodule ServiceRadar.NetworkDiscovery.MapperGraphIngestionTest do
  use ServiceRadar.DataCase, async: false

  alias Ecto.Adapters.SQL
  alias ServiceRadar.NetworkDiscovery.MapperResultsIngestor
  alias ServiceRadar.NetworkDiscovery.TopologyGraph
  alias ServiceRadar.NetworkDiscovery.TopologyGraph.Links
  alias ServiceRadar.Repo
  alias ServiceRadar.TestSupport

  @moduletag :integration

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    if age_available?() do
      graph_name = graph_name()

      case ensure_graph(graph_name) do
        :ok ->
          :ok

        {:error, reason} ->
          {:ok, skip: "Apache AGE graph #{graph_name} not available: #{inspect(reason)}"}
      end
    else
      {:ok, skip: "Apache AGE is not available (ag_catalog.cypher missing)"}
    end
  end

  setup do
    clear_report_fingerprints()
    on_exit(&clear_report_fingerprints/0)
    Application.put_env(:serviceradar_core, :mapper_topology_edge_stale_minutes, 180)

    cleanup_graph(
      [
        "sr:dev-1",
        "sr:dev-host77",
        "sr:dev-host77/192.168.1.77",
        "sr:dev-2",
        "sr:dev-3",
        "sr:dev-router",
        "sr:dev-switch-a",
        "sr:dev-switch-b",
        "sr:dev-ap",
        "sr:dev-dist",
        "sr:aruba",
        "sr:tonka",
        "sr:zz-mikrotik",
        "sr:dev-1/eth0",
        "sr:dev-1/eth2",
        "sr:dev-1/unknown-local",
        "sr:dev-2/Gi1/0/1",
        "sr:dev-2/aa:bb:cc:dd:ee:ff",
        "sr:dev-2/eth1",
        "sr:dev-3/eth5",
        "sr:dev-router/eth0",
        "sr:dev-switch-a/uplink",
        "sr:dev-switch-b/uplink",
        "sr:dev-ap/wifi0",
        "sr:dev-dist/xe-0/0/1",
        "sr:aruba/23",
        "sr:tonka/eth4",
        "sr:zz-mikrotik/ether1"
      ] ++ sparse_payload_ids() ++ synthetic_topology_ids()
    )

    :ok
  end

  test "upsert_interfaces creates interface nodes and HAS_INTERFACE edges" do
    now = DateTime.truncate(DateTime.utc_now(), :microsecond)

    TopologyGraph.upsert_interfaces([
      %{
        device_id: "sr:dev-1",
        if_name: "eth0",
        if_index: 10,
        if_descr: "Uplink",
        if_alias: "uplink",
        if_phys_address: "AA:BB:CC:DD:EE:FF",
        ip_addresses: ["192.0.2.10"],
        created_at: now
      }
    ])

    [result] =
      cypher_rows(
        ~s/MATCH (d:Device {id:'sr:dev-1'})-[:HAS_INTERFACE]->(i:Interface {id:'sr:dev-1\/eth0'})
      RETURN {name: i.name, ifindex: i.ifindex, alias: i.alias, ip_addresses: i.ip_addresses} AS result/
      )

    assert result["name"] == "eth0"
    assert result["ifindex"] == 10
    assert result["alias"] == "uplink"
    assert result["ip_addresses"] == ["192.0.2.10"]
  end

  test "upsert_links creates CONNECTS_TO edges between interfaces" do
    now = DateTime.truncate(DateTime.utc_now(), :microsecond)

    TopologyGraph.upsert_links([
      %{
        local_device_id: "sr:dev-1",
        neighbor_device_id: "sr:dev-2",
        local_if_name: "eth0",
        local_if_index: 10,
        neighbor_port_id: "Gi1/0/1",
        protocol: "lldp",
        metadata: %{"confidence_tier" => "high", "confidence_score" => 95},
        timestamp: now,
        created_at: now
      }
    ])

    [result] =
      cypher_rows(
        ~s/MATCH (a:Interface {id:'sr:dev-1\/eth0'})-[r:CONNECTS_TO]->(b:Interface {id:'sr:dev-2\/Gi1\/0\/1'})
      RETURN {source: r.source, tier: r.confidence_tier, score: r.confidence_score} AS result/
      )

    assert result["source"] == "lldp"
    assert result["tier"] == "high"
    assert result["score"] == 95
  end

  test "upsert_links reapplies every mutable projected device and interface property" do
    now = DateTime.truncate(DateTime.utc_now(), :microsecond)

    link = %{
      local_device_id: "sr:dev-1",
      local_device_ip: "192.0.2.10",
      neighbor_device_id: "sr:dev-2",
      neighbor_system_name: "switch-a",
      neighbor_mgmt_addr: "192.0.2.20",
      local_if_name: "eth0",
      local_if_index: 10,
      neighbor_port_id: "aa:bb:cc:dd:ee:ff",
      protocol: "lldp",
      metadata: %{"confidence_tier" => "high", "confidence_score" => 95},
      timestamp: now,
      created_at: now
    }

    TopologyGraph.upsert_links([link])

    link = %{link | local_device_ip: "192.0.2.11"}
    TopologyGraph.upsert_links([link])
    [result] = cypher_rows("MATCH (d:Device {id:'sr:dev-1'}) RETURN {value: d.ip} AS result")
    assert result["value"] == "192.0.2.11"

    link = %{link | neighbor_system_name: "switch-b"}
    TopologyGraph.upsert_links([link])

    [result] =
      cypher_rows("MATCH (d:Device {id:'sr:dev-2'}) RETURN {value: d.name} AS result")

    assert result["value"] == "switch-b"

    link = %{link | neighbor_mgmt_addr: "192.0.2.21"}
    TopologyGraph.upsert_links([link])
    [result] = cypher_rows("MATCH (d:Device {id:'sr:dev-2'}) RETURN {value: d.ip} AS result")
    assert result["value"] == "192.0.2.21"

    link = %{link | local_if_index: 11}
    TopologyGraph.upsert_links([link])

    [result] =
      cypher_rows("MATCH (i:Interface {id:'sr:dev-1/eth0'}) RETURN {value: i.ifindex} AS result")

    assert result["value"] == 11

    # Whitespace changes the projected property but not its normalized vertex ID.
    link = %{link | local_if_name: " eth0 "}
    TopologyGraph.upsert_links([link])

    [result] =
      cypher_rows("MATCH (i:Interface {id:'sr:dev-1/eth0'}) RETURN {value: i.name} AS result")

    assert result["value"] == " eth0 "

    # Both spellings normalize to one vertex ID, but the projected name changed.
    link = %{link | neighbor_port_id: "aabbccddeeff"}
    TopologyGraph.upsert_links([link])

    [result] =
      cypher_rows(
        "MATCH (i:Interface {id:'sr:dev-2/aa:bb:cc:dd:ee:ff'}) RETURN {value: i.name} AS result"
      )

    assert result["value"] == "aabbccddeeff"
  end

  test "upsert_links falls back when neighbor port metadata is missing" do
    now = DateTime.truncate(DateTime.utc_now(), :microsecond)

    TopologyGraph.upsert_links([
      %{
        local_device_id: "sr:dev-1",
        neighbor_device_id: "sr:dev-2",
        local_if_index: 21,
        neighbor_chassis_id: "aa:bb:cc:dd:ee:ff",
        protocol: "UniFi-API",
        metadata: %{"confidence_tier" => "medium", "confidence_score" => 72},
        timestamp: now,
        created_at: now
      }
    ])

    [result] =
      cypher_rows(
        ~s/MATCH (a:Interface {id:'sr:dev-1\/ifindex:21'})-[r:CONNECTS_TO]->(b:Interface {id:'sr:dev-2\/aa:bb:cc:dd:ee:ff'})
      RETURN {source: r.source, tier: r.confidence_tier} AS result/
      )

    assert result["source"] == "UniFi-API"
    assert result["tier"] == "medium"
  end

  test "upsert_links skips low-confidence links from AGE projection" do
    now = DateTime.truncate(DateTime.utc_now(), :microsecond)

    TopologyGraph.upsert_links([
      %{
        local_device_id: "sr:dev-1",
        neighbor_device_id: "sr:dev-2",
        local_if_name: "eth0",
        neighbor_port_id: "eth1",
        protocol: "unknown",
        metadata: %{"confidence_tier" => "low", "confidence_score" => 20},
        timestamp: now,
        created_at: now
      }
    ])

    [result] =
      cypher_rows(
        ~s/MATCH (a:Interface {id:'sr:dev-1\/eth0'})-[r:CONNECTS_TO]->(b:Interface {id:'sr:dev-2\/eth1'})
      RETURN {count: count(r)} AS result/
      )

    assert result["count"] == 0
  end

  test "upsert_links drops LLDP edges without a local interface index" do
    now = DateTime.truncate(DateTime.utc_now(), :microsecond)

    TopologyGraph.upsert_links([
      %{
        local_device_id: "sr:dev-1",
        neighbor_device_id: "sr:dev-2",
        local_if_name: "eth0",
        local_if_index: nil,
        neighbor_port_id: "eth1",
        protocol: "lldp",
        metadata: %{"confidence_tier" => "high", "confidence_score" => 95},
        timestamp: now,
        created_at: now
      }
    ])

    [result] =
      cypher_rows(
        ~s/MATCH (a:Interface {id:'sr:dev-1\/eth0'})-[r:CONNECTS_TO]->(b:Interface {id:'sr:dev-2\/eth1'})
      RETURN {count: count(r)} AS result/
      )

    assert result["count"] == 1
  end

  test "upsert_links keeps SNMP-L2 inferred edges without a local interface index" do
    now = DateTime.truncate(DateTime.utc_now(), :microsecond)

    TopologyGraph.upsert_links([
      %{
        local_device_id: "sr:dev-1",
        neighbor_device_id: "sr:dev-2",
        local_if_name: "eth0",
        local_if_index: nil,
        neighbor_port_id: "eth1",
        protocol: "snmp-l2",
        metadata: %{"confidence_tier" => "medium", "confidence_score" => 72},
        timestamp: now,
        created_at: now
      }
    ])

    [result] =
      cypher_rows(
        ~s/MATCH (a:Interface {id:'sr:dev-1\/eth0'})-[r:INFERRED_TO]->(b:Interface {id:'sr:dev-2\/eth1'})
      RETURN {count: count(r), source: head(collect(r.source))} AS result/
      )

    assert result["count"] == 1
    assert result["source"] == "snmp-l2"
  end

  test "upsert_links drops low-confidence single-identifier inferred edges" do
    now = DateTime.truncate(DateTime.utc_now(), :microsecond)

    TopologyGraph.upsert_links([
      %{
        local_device_id: "sr:dev-1",
        neighbor_device_id: "sr:dev-2",
        local_if_name: "eth0",
        local_if_index: nil,
        neighbor_port_id: "eth1",
        protocol: "snmp-l2",
        metadata: %{
          "confidence_tier" => "low",
          "confidence_score" => 40,
          "confidence_reason" => "single_identifier_inference"
        },
        timestamp: now,
        created_at: now
      }
    ])

    [result] =
      cypher_rows(
        ~s/MATCH (a:Interface {id:'sr:dev-1\/eth0'})-[r:INFERRED_TO]->(b:Interface {id:'sr:dev-2\/eth1'})
      RETURN {count: count(r)} AS result/
      )

    assert result["count"] == 0
  end

  test "mapper SNMP ARP/FDB single-identifier payload with unresolved neighbor is dropped before AGE projection" do
    now = DateTime.truncate(DateTime.utc_now(), :microsecond)

    normalized =
      MapperResultsIngestor.normalize_topology(%{
        "timestamp" => now,
        "protocol" => "SNMP-L2",
        "local_device_id" => "sr:dev-router",
        "local_device_ip" => "192.168.1.1",
        "local_if_name" => "eth0",
        "local_if_index" => nil,
        "neighbor_mgmt_addr" => "192.168.1.77",
        "neighbor_port_id" => nil,
        "metadata" => %{
          "source" => "snmp-arp-fdb",
          "evidence" => "ipNetToMedia+dot1dTpFdb"
        }
      })

    assert normalized.metadata["confidence_reason"] == "single_identifier_inference"
    assert normalized.metadata["evidence_class"] == "observed-only"

    TopologyGraph.upsert_links([Map.put(normalized, :created_at, now)])

    # Pre-fix the projection fabricated a raw-IP pseudo-vertex ('192.168.1.77')
    # that every consumer filtered out anyway. Post-fix the unresolved neighbor
    # is dropped before projection: no edge of any relation type, and no
    # non-`sr:` vertex, may be written to AGE.
    for relation <- ["CONNECTS_TO", "INFERRED_TO", "ATTACHED_TO", "OBSERVED_TO"] do
      [result] =
        cypher_rows(
          "MATCH (a:Interface {id:'sr:dev-router/eth0'})-[r:#{relation}]->(b:Interface) " <>
            "RETURN {count: count(r)} AS result"
        )

      assert result["count"] == 0,
             "expected no #{relation} edge for unresolved neighbor, got #{inspect(result)}"
    end

    [pseudo_vertex] =
      cypher_rows(
        "MATCH (i:Interface {id:'192.168.1.77/192.168.1.77'}) RETURN {count: count(i)} AS result"
      )

    assert pseudo_vertex["count"] == 0
  end

  test "mapper SNMP ARP/FDB payload with a managed neighbor projects as inferred evidence" do
    now = DateTime.truncate(DateTime.utc_now(), :microsecond)

    normalized =
      MapperResultsIngestor.normalize_topology(%{
        "timestamp" => now,
        "protocol" => "SNMP-L2",
        "local_device_id" => "sr:dev-router",
        "local_device_ip" => "192.168.1.1",
        "local_if_name" => "eth0",
        "local_if_index" => nil,
        "neighbor_device_id" => "sr:dev-host77",
        "neighbor_mgmt_addr" => "192.168.1.77",
        "neighbor_port_id" => nil,
        "metadata" => %{
          "source" => "snmp-arp-fdb",
          "evidence" => "ipNetToMedia+dot1dTpFdb"
        }
      })

    assert normalized.metadata["confidence_reason"] == "managed_neighbor_identifier"
    assert normalized.metadata["evidence_class"] == "inferred-segment"
    assert normalized.metadata["relation_family"] == "INFERRED_TO"

    TopologyGraph.upsert_links([Map.put(normalized, :created_at, now)])

    neighbor_interface_id = "sr:dev-host77/192.168.1.77"

    [connects] =
      cypher_rows(
        "MATCH (a:Interface {id:'sr:dev-router/eth0'})-[r:CONNECTS_TO]->(b:Interface {id:'#{neighbor_interface_id}'}) " <>
          "RETURN {count: count(r)} AS result"
      )

    [inferred] =
      cypher_rows(
        "MATCH (a:Interface {id:'sr:dev-router/eth0'})-[r:INFERRED_TO]->(b:Interface {id:'#{neighbor_interface_id}'}) " <>
          "RETURN {count: count(r)} AS result"
      )

    [attached] =
      cypher_rows(
        "MATCH (a:Interface {id:'sr:dev-router/eth0'})-[r:ATTACHED_TO]->(b:Interface {id:'#{neighbor_interface_id}'}) " <>
          "RETURN {count: count(r), source: head(collect(r.source))} AS result"
      )

    [observed] =
      cypher_rows(
        "MATCH (a:Interface {id:'sr:dev-router/eth0'})-[r:OBSERVED_TO]->(b:Interface {id:'#{neighbor_interface_id}'}) " <>
          "RETURN {count: count(r), source: head(collect(r.source))} AS result"
      )

    assert connects["count"] == 0
    assert inferred["count"] == 1
    assert attached["count"] == 0
    assert observed["count"] == 0
  end

  test "upsert_links keeps multiple resolved SNMP-L2 neighbors for one local device" do
    now = DateTime.truncate(DateTime.utc_now(), :microsecond)

    TopologyGraph.upsert_links([
      %{
        local_device_id: "sr:dev-1",
        neighbor_device_id: "sr:dev-2",
        local_if_name: "eth0",
        local_if_index: nil,
        neighbor_port_id: "eth1",
        protocol: "snmp-l2",
        metadata: %{"confidence_tier" => "medium", "confidence_score" => 72},
        timestamp: now,
        created_at: now
      },
      %{
        local_device_id: "sr:dev-1",
        neighbor_device_id: "sr:dev-3",
        local_if_name: "eth0",
        local_if_index: nil,
        neighbor_port_id: "eth9",
        protocol: "snmp-l2",
        metadata: %{"confidence_tier" => "medium", "confidence_score" => 70},
        timestamp: now,
        created_at: now
      }
    ])

    [result] =
      cypher_rows(
        ~s/MATCH (a:Interface {id:'sr:dev-1\/eth0'})-[r:INFERRED_TO]->(b:Interface) WHERE b.device_id IN ['sr:dev-2','sr:dev-3']
      RETURN {count: count(r)} AS result/
      )

    assert result["count"] == 2
  end

  test "upsert_links preserves UniFi direct neighbors when SNMP-L2 fallback is also present" do
    now = DateTime.truncate(DateTime.utc_now(), :microsecond)

    TopologyGraph.upsert_links([
      %{
        local_device_id: "sr:dev-1",
        neighbor_device_id: "sr:dev-2",
        local_if_name: "eth0",
        local_if_index: 21,
        neighbor_port_id: "Gi1/0/1",
        protocol: "unifi-api",
        metadata: %{"confidence_tier" => "medium", "confidence_score" => 78},
        timestamp: now,
        created_at: now
      },
      %{
        local_device_id: "sr:dev-1",
        neighbor_device_id: "sr:dev-3",
        local_if_name: "eth0",
        local_if_index: 21,
        neighbor_port_id: "Gi1/0/2",
        protocol: "unifi-api",
        metadata: %{"confidence_tier" => "medium", "confidence_score" => 78},
        timestamp: now,
        created_at: now
      },
      %{
        local_device_id: "sr:dev-1",
        neighbor_device_id: "sr:dev-router",
        local_if_name: "eth0",
        local_if_index: 21,
        neighbor_port_id: "eth0",
        protocol: "snmp-l2",
        metadata: %{"confidence_tier" => "medium", "confidence_score" => 70},
        timestamp: now,
        created_at: now
      }
    ])

    [result] =
      cypher_rows(~s/MATCH (a:Interface {id:'sr:dev-1\/eth0'})-[r:CONNECTS_TO]->(b:Interface)
      WHERE b.device_id IN ['sr:dev-2', 'sr:dev-3']
      RETURN {count: count(r), neighbors: collect(distinct b.device_id)} AS result/)

    assert result["count"] == 2
    assert Enum.sort(result["neighbors"]) == ["sr:dev-2", "sr:dev-3"]
  end

  test "upsert_links is idempotent and updates confidence metadata in place" do
    now = DateTime.truncate(DateTime.utc_now(), :microsecond)
    later = DateTime.add(now, 30, :second)

    TopologyGraph.upsert_links([
      %{
        local_device_id: "sr:dev-1",
        neighbor_device_id: "sr:dev-2",
        local_if_name: "eth0",
        local_if_index: 10,
        neighbor_port_id: "eth1",
        protocol: "lldp",
        metadata: %{"confidence_tier" => "medium", "confidence_score" => 66},
        timestamp: now,
        created_at: now
      }
    ])

    TopologyGraph.upsert_links([
      %{
        local_device_id: "sr:dev-1",
        neighbor_device_id: "sr:dev-2",
        local_if_name: "eth0",
        local_if_index: 10,
        neighbor_port_id: "eth1",
        protocol: "lldp",
        metadata: %{"confidence_tier" => "high", "confidence_score" => 95},
        timestamp: later,
        created_at: later
      }
    ])

    [count_result] =
      cypher_rows(
        ~s/MATCH (a:Interface {id:'sr:dev-1\/eth0'})-[r:CONNECTS_TO]->(b:Interface {id:'sr:dev-2\/eth1'})
      RETURN {count: count(r)} AS result/
      )

    [edge_result] =
      cypher_rows(
        ~s/MATCH (a:Interface {id:'sr:dev-1\/eth0'})-[r:CONNECTS_TO]->(b:Interface {id:'sr:dev-2\/eth1'})
      RETURN {tier: r.confidence_tier, score: r.confidence_score, last: r.last_observed_at} AS result/
      )

    assert count_result["count"] == 1
    assert edge_result["tier"] == "high"
    assert edge_result["score"] == 95
    assert is_binary(edge_result["last"])
  end

  test "upsert_links prunes stale projected edges by observation timestamp" do
    Application.put_env(:serviceradar_core, :mapper_topology_edge_stale_minutes, 1)

    Application.put_env(
      :serviceradar_core,
      :mapper_topology_prune_stale_projected_links_enabled,
      true
    )

    on_exit(fn ->
      Application.delete_env(
        :serviceradar_core,
        :mapper_topology_prune_stale_projected_links_enabled
      )
    end)

    now = DateTime.truncate(DateTime.utc_now(), :microsecond)
    stale = DateTime.add(now, -10 * 60, :second)

    TopologyGraph.upsert_links([
      %{
        local_device_id: "sr:dev-1",
        neighbor_device_id: "sr:dev-2",
        local_if_name: "eth0",
        local_if_index: 10,
        neighbor_port_id: "eth1",
        protocol: "lldp",
        metadata: %{"confidence_tier" => "high", "confidence_score" => 95},
        timestamp: stale,
        created_at: stale
      }
    ])

    TopologyGraph.upsert_links([
      %{
        local_device_id: "sr:dev-1",
        neighbor_device_id: "sr:dev-3",
        local_if_name: "eth2",
        local_if_index: 12,
        neighbor_port_id: "eth5",
        protocol: "lldp",
        metadata: %{"confidence_tier" => "high", "confidence_score" => 95},
        timestamp: now,
        created_at: now
      }
    ])

    [stale_result] =
      cypher_rows(
        ~s/MATCH (a:Interface {id:'sr:dev-1\/eth0'})-[r:CONNECTS_TO]->(b:Interface {id:'sr:dev-2\/eth1'})
      RETURN {count: count(r)} AS result/
      )

    [fresh_result] =
      cypher_rows(
        ~s/MATCH (a:Interface {id:'sr:dev-1\/eth2'})-[r:CONNECTS_TO]->(b:Interface {id:'sr:dev-3\/eth5'})
      RETURN {count: count(r)} AS result/
      )

    assert stale_result["count"] == 0
    assert fresh_result["count"] == 1
  end

  test "synthetic topology replay projects expected farm01 and tonka01 connectivity" do
    now = DateTime.truncate(DateTime.utc_now(), :microsecond)
    fixture = synthetic_topology_fixture(now)
    payload = Jason.encode!(fixture.links)

    assert :ok = MapperResultsIngestor.ingest_topology(payload, %{})

    [count_result] =
      cypher_rows(
        "MATCH (:Interface)-[r:CONNECTS_TO]->(:Interface) RETURN {count: count(r)} AS result"
      )

    assert count_result["count"] >= 1

    Enum.each(
      [
        {"sr:farm01", "sr:uswagg"},
        {"sr:tonka01", "sr:aruba-10-154"}
      ],
      fn {from_id, to_id} ->
        [result] =
          cypher_rows(
            "MATCH (a:Device)-[r:CANONICAL_TOPOLOGY]->(b:Device) " <>
              "WHERE (a.id = '#{from_id}' AND b.id = '#{to_id}') " <>
              "   OR (a.id = '#{to_id}' AND b.id = '#{from_id}') " <>
              "RETURN {count: count(r), relation_type: head(collect(r.relation_type))} AS result"
          )

        assert result["count"] == 1,
               "missing expected device connectivity #{from_id} -> #{to_id}, got #{inspect(result)}"

        assert result["relation_type"] in ["CONNECTS_TO", "ATTACHED_TO"]
      end
    )
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
  # TopologyGraph.upsert_links/1. Post-fix everything persists and the LLDP
  # edge landing in AGE proves the graph projection ran for the same payload.
  test "ingest_topology with mixed sparse and rich records persists all and projects to AGE" do
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

    [edge] =
      cypher_rows(
        ~s/MATCH (a:Interface {id:'sr:it-mix-a\/eth0'})-[r:CONNECTS_TO]->(b:Interface {id:'sr:it-mix-b\/Gi0\/1'})
      RETURN {count: count(r)} AS result/
      )

    assert edge["count"] == 1
  end

  test "router drops low-confidence inferred neighbors when only the uplink is corroborated" do
    now = DateTime.truncate(DateTime.utc_now(), :microsecond)

    insert_device_type("sr:dev-router", "Router")
    insert_device_type("sr:dev-switch-a", "Switch")
    insert_device_type("sr:dev-switch-b", "Switch")
    insert_device_type("sr:dev-ap", "Access Point")
    insert_device_type("sr:dev-dist", "Switch")

    TopologyGraph.upsert_links([
      %{
        local_device_id: "sr:dev-router",
        neighbor_device_id: "sr:dev-switch-a",
        local_if_name: "eth0",
        local_if_index: 28,
        neighbor_port_id: "uplink",
        protocol: "snmp-l2",
        metadata: %{"confidence_tier" => "low", "confidence_score" => 40},
        timestamp: now,
        created_at: now
      },
      %{
        local_device_id: "sr:dev-router",
        neighbor_device_id: "sr:dev-switch-b",
        local_if_name: "eth0",
        local_if_index: 28,
        neighbor_port_id: "uplink",
        protocol: "snmp-l2",
        metadata: %{"confidence_tier" => "low", "confidence_score" => 40},
        timestamp: now,
        created_at: now
      },
      %{
        local_device_id: "sr:dev-router",
        neighbor_device_id: "sr:dev-ap",
        local_if_name: "eth0",
        local_if_index: 28,
        neighbor_port_id: "wifi0",
        protocol: "snmp-l2",
        metadata: %{"confidence_tier" => "low", "confidence_score" => 40},
        timestamp: now,
        created_at: now
      },
      %{
        local_device_id: "sr:dev-dist",
        neighbor_device_id: "sr:dev-switch-a",
        local_if_name: "xe-0/0/1",
        local_if_index: 10,
        neighbor_port_id: "uplink",
        protocol: "lldp",
        metadata: %{"confidence_tier" => "high", "confidence_score" => 95},
        timestamp: now,
        created_at: now
      }
    ])

    [result] =
      cypher_rows(
        ~s/MATCH (a:Device)-[r:CANONICAL_TOPOLOGY]->(b:Device)
      WHERE (a.id = 'sr:dev-router' AND b.id = 'sr:dev-switch-a')
         OR (a.id = 'sr:dev-switch-a' AND b.id = 'sr:dev-router')
      RETURN {count: count(r), relation_type: head(collect(r.relation_type)), confidence_reason: head(collect(r.confidence_reason))} AS result/
      )

    assert result["count"] == 0

    [rejected] =
      cypher_rows(~s/MATCH (a:Device)-[r:CANONICAL_TOPOLOGY]->(b:Device)
      WHERE (a.id = 'sr:dev-router' AND b.id = 'sr:dev-switch-b')
         OR (a.id = 'sr:dev-switch-b' AND b.id = 'sr:dev-router')
      RETURN {count: count(r)} AS result/)

    assert rejected["count"] == 0
  end

  test "canonical rebuild demotes competing same-port direct neighbor to attachment when uplink is corroborated" do
    now = DateTime.truncate(DateTime.utc_now(), :microsecond)

    TopologyGraph.upsert_links([
      %{
        local_device_id: "sr:aruba",
        neighbor_device_id: "sr:tonka",
        local_if_name: "23",
        local_if_index: 23,
        neighbor_port_id: "eth4",
        protocol: "lldp",
        metadata: %{"confidence_tier" => "high", "confidence_score" => 95},
        timestamp: now,
        created_at: now
      },
      %{
        local_device_id: "sr:aruba",
        neighbor_device_id: "sr:zz-mikrotik",
        local_if_name: "23",
        local_if_index: 23,
        neighbor_port_id: "ether1",
        protocol: "lldp",
        metadata: %{"confidence_tier" => "high", "confidence_score" => 95},
        timestamp: now,
        created_at: now
      },
      %{
        local_device_id: "sr:aruba",
        neighbor_device_id: "sr:tonka",
        local_if_name: "23",
        local_if_index: 23,
        neighbor_port_id: "eth4",
        protocol: "snmp-l2",
        metadata: %{
          "confidence_tier" => "medium",
          "confidence_score" => 72,
          "confidence_reason" => "arp_fdb_port_mapping",
          "evidence_class" => "inferred"
        },
        timestamp: now,
        created_at: now
      }
    ])

    results =
      cypher_rows("""
      MATCH (a:Device)-[r:CANONICAL_TOPOLOGY]->(b:Device)
      WHERE (a.id = 'sr:aruba' AND b.id IN ['sr:tonka', 'sr:zz-mikrotik'])
         OR (b.id = 'sr:aruba' AND a.id IN ['sr:tonka', 'sr:zz-mikrotik'])
      RETURN {
        neighbor: CASE WHEN a.id = 'sr:aruba' THEN b.id ELSE a.id END,
        relation_type: r.relation_type,
        evidence_class: r.evidence_class,
        confidence_reason: r.confidence_reason
      } AS result
      """)

    assert results |> Enum.map(& &1["neighbor"]) |> Enum.sort() == ["sr:tonka", "sr:zz-mikrotik"]

    assert Enum.any?(results, fn row ->
             row["neighbor"] == "sr:tonka" and row["relation_type"] == "CONNECTS_TO" and
               row["evidence_class"] == "direct-physical"
           end)

    assert Enum.any?(results, fn row ->
             row["neighbor"] == "sr:zz-mikrotik" and row["relation_type"] == "ATTACHED_TO" and
               row["evidence_class"] == "endpoint-attachment" and
               row["confidence_reason"] == "shared_segment_via_uplink"
           end)
  end

  defp sparse_payload_ids do
    [
      "sr:it-fdb-switch",
      "sr:it-unifi-ap",
      "sr:it-unifi-switch",
      "sr:it-wg-router-a",
      "sr:it-wg-router-b",
      "sr:it-mix-a",
      "sr:it-mix-b",
      "sr:it-mix-sw",
      "sr:it-fdb-switch/ifindex:4",
      "sr:it-unifi-ap/wireless",
      "sr:it-unifi-switch/Port 24",
      "sr:it-wg-router-a/wg0",
      "sr:it-wg-router-b/wg0",
      "sr:it-mix-a/eth0",
      "sr:it-mix-a/wireless",
      "sr:it-mix-b/Gi0/1",
      "sr:it-mix-sw/ifindex:7"
    ]
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

  defp insert_device_type(uid, type) do
    SQL.query!(
      Repo,
      """
      INSERT INTO ocsf_devices (uid, type, name, hostname, created_time, modified_time)
      VALUES ($1, $2, $1, $1, NOW(), NOW())
      ON CONFLICT (uid) DO UPDATE SET type = EXCLUDED.type, modified_time = NOW()
      """,
      [uid, type]
    )
  end

  defp age_available? do
    with {:ok, %Postgrex.Result{rows: [[_]]}} <-
           SQL.query(Repo, "SELECT 1 FROM pg_namespace WHERE nspname = 'ag_catalog'", []),
         {:ok, %Postgrex.Result{rows: [[_]]}} <-
           SQL.query(
             Repo,
             """
             SELECT 1
             FROM pg_proc p
             JOIN pg_namespace n ON n.oid = p.pronamespace
             WHERE n.nspname = 'ag_catalog' AND p.proname = 'cypher'
             LIMIT 1
             """,
             []
           ) do
      true
    else
      _ -> false
    end
  rescue
    _ -> false
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

  defp ensure_graph(graph_name) do
    case SQL.query(Repo, "SELECT 1 FROM ag_catalog.ag_graph WHERE name = $1 LIMIT 1", [graph_name]) do
      {:ok, %Postgrex.Result{num_rows: 1}} ->
        :ok

      {:ok, _} ->
        case SQL.query(Repo, "SELECT ag_catalog.create_graph($1)", [graph_name]) do
          {:ok, _} -> :ok
          {:error, err} -> {:error, err}
        end

      {:error, err} ->
        {:error, err}
    end
  rescue
    err -> {:error, err}
  end

  defp cleanup_graph(ids) when is_list(ids) do
    quoted_ids = Enum.map_join(ids, ", ", &("'" <> &1 <> "'"))
    graph = String.replace(graph_name(), "'", "\\'")

    cypher = "MATCH (n) WHERE n.id IN [#{quoted_ids}] DETACH DELETE n"

    _ =
      SQL.query(
        Repo,
        "SELECT ag_catalog.agtype_to_text(v) FROM ag_catalog.cypher('#{graph}', $$#{cypher}$$) AS (v agtype)",
        []
      )

    :ok
  end

  defp cypher_rows(cypher) do
    graph = String.replace(graph_name(), "'", "\\'")

    sql = """
    SELECT ag_catalog.agtype_to_text(result)
    FROM ag_catalog.cypher('#{graph}', $$#{cypher}$$) AS (result agtype)
    """

    case SQL.query(Repo, sql, []) do
      {:ok, %Postgrex.Result{rows: rows}} ->
        Enum.map(rows, fn
          [text_value] when is_binary(text_value) -> decode_agtype(text_value)
          row -> row
        end)

      {:error, error} ->
        raise "cypher query failed: #{inspect(error)}"
    end
  end

  defp decode_agtype(text_value) do
    case Jason.decode(text_value) do
      {:ok, parsed} -> parsed
      {:error, _} -> text_value
    end
  end

  defp graph_name do
    Application.get_env(:serviceradar_core, :age_graph_name, "platform_graph")
  end

  defp synthetic_topology_ids do
    now = DateTime.truncate(DateTime.utc_now(), :microsecond)

    now
    |> synthetic_topology_fixture()
    |> Map.fetch!(:links)
    |> Enum.flat_map(fn link ->
      [
        link["local_device_id"],
        link["neighbor_device_id"],
        "#{link["local_device_id"]}/#{link["local_if_name"]}",
        "#{link["neighbor_device_id"]}/#{link["neighbor_port_id"]}"
      ]
    end)
    |> Enum.uniq()
  end

  defp synthetic_topology_fixture(now) do
    links = [
      synthetic_link(
        "sr:farm01",
        "sr:uswagg",
        "lan-core",
        "port-1",
        "198.18.1.1",
        "198.18.1.87",
        "USWAggregation",
        now
      ),
      synthetic_link(
        "sr:uswagg",
        "sr:usw16poe",
        "port-10",
        "port-1",
        "198.18.1.87",
        "198.18.1.138",
        "USW16PoE",
        now
      ),
      synthetic_link(
        "sr:uswagg",
        "sr:uswpro24-a",
        "port-31",
        "port-1",
        "198.18.1.87",
        "198.18.1.131",
        "USWPro24-A",
        now
      ),
      synthetic_link(
        "sr:uswagg",
        "sr:uswpro24-b",
        "port-35",
        "port-1",
        "198.18.1.87",
        "198.18.1.195",
        "USWPro24-B",
        now
      ),
      synthetic_link(
        "sr:usw16poe",
        "sr:u6lr",
        "port-5",
        "eth0",
        "198.18.1.138",
        "198.18.1.130",
        "U6LR",
        now
      ),
      synthetic_link(
        "sr:usw16poe",
        "sr:u6mesh-16",
        "port-6",
        "eth0",
        "198.18.1.138",
        "198.18.1.16",
        "U6Mesh-16",
        now
      ),
      synthetic_link(
        "sr:usw16poe",
        "sr:uswlite8",
        "port-7",
        "port-1",
        "198.18.1.138",
        "198.18.1.238",
        "USWLite8PoE",
        now
      ),
      synthetic_link(
        "sr:usw16poe",
        "sr:u6mesh-96",
        "port-8",
        "eth0",
        "198.18.1.138",
        "198.18.1.96",
        "U6Mesh-96",
        now
      ),
      synthetic_link(
        "sr:uswlite8",
        "sr:u6mesh-200",
        "port-2",
        "eth0",
        "198.18.1.238",
        "198.18.1.200",
        "U6Mesh-200",
        now
      ),
      synthetic_link(
        "sr:uswpro24-b",
        "sr:nanohd",
        "port-22",
        "eth0",
        "198.18.1.195",
        "198.18.1.233",
        "NanoHD",
        now
      ),
      synthetic_link(
        "sr:tonka01",
        "sr:aruba-10-154",
        "lan10",
        "uplink",
        "198.18.10.1",
        "198.18.10.154",
        "ArubaSwitch",
        now
      ),
      synthetic_link(
        "sr:aruba-10-154",
        "sr:endpoint-10-96",
        "port-5",
        "eth0",
        "198.18.10.154",
        "198.18.10.96",
        "Endpoint-10-96",
        now
      )
    ]

    expected_edges =
      Enum.map(links, fn link ->
        {"#{link["local_device_id"]}/#{link["local_if_name"]}",
         "#{link["neighbor_device_id"]}/#{link["neighbor_port_id"]}"}
      end)

    %{links: links, expected_edges: expected_edges}
  end

  defp synthetic_link(
         local_id,
         neighbor_id,
         local_if,
         neighbor_port,
         local_ip,
         neighbor_ip,
         neighbor_name,
         now
       ) do
    %{
      "protocol" => "LLDP",
      "agent_id" => "agent-dusk",
      "gateway_id" => "agent-dusk",
      "partition" => "default",
      "local_device_id" => local_id,
      "local_device_ip" => local_ip,
      "local_if_name" => local_if,
      "local_if_index" => synthetic_ifindex(local_if),
      "neighbor_device_id" => neighbor_id,
      "neighbor_port_id" => neighbor_port,
      "neighbor_system_name" => neighbor_name,
      "neighbor_mgmt_addr" => neighbor_ip,
      "metadata" => %{"source" => "synthetic-fixture"},
      "timestamp" => now
    }
  end

  defp synthetic_ifindex(name) when is_binary(name) do
    case Regex.run(~r/(\d+)/, name, capture: :all_but_first) do
      [digits] ->
        case Integer.parse(digits) do
          {value, ""} when value > 0 -> value
          _ -> 1
        end

      _ ->
        :erlang.phash2(name, 4_094) + 1
    end
  end

  defp synthetic_ifindex(_), do: 1
end
