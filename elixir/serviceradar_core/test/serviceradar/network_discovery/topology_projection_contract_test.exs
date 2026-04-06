defmodule ServiceRadar.NetworkDiscovery.TopologyProjectionContractTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.NetworkDiscovery.MapperResultsIngestor
  alias ServiceRadar.NetworkDiscovery.TopologyGraph

  describe "classify_projection/1 contract" do
    test "LLDP direct neighbor projects to backbone CONNECTS_TO" do
      normalized =
        MapperResultsIngestor.normalize_topology(%{
          "protocol" => "LLDP",
          "local_device_id" => "dev-a",
          "local_device_ip" => "192.168.1.87",
          "local_if_index" => 7,
          "local_if_name" => "sfp+7",
          "neighbor_device_id" => "dev-b",
          "neighbor_port_id" => "sfp+1",
          "neighbor_mgmt_addr" => "192.168.1.138",
          "metadata" => %{"source" => "snmp-lldp"}
        })

      assert {:ok, %{mode: :backbone, relation: "CONNECTS_TO", reason: :projected_backbone}} =
               TopologyGraph.classify_projection(normalized)
    end

    test "SNMP ARP/FDB single-identifier evidence stays observation-only" do
      normalized =
        MapperResultsIngestor.normalize_topology(%{
          "protocol" => "SNMP-L2",
          "local_device_id" => "dev-router",
          "local_device_ip" => "192.168.1.1",
          "local_if_name" => "eth0",
          "neighbor_mgmt_addr" => "192.168.1.77",
          "metadata" => %{
            "source" => "snmp-arp-fdb",
            "evidence" => "ipNetToMedia+dot1dTpFdb"
          }
        })

      assert normalized.metadata["confidence_reason"] == "single_identifier_inference"
      assert normalized.metadata["evidence_class"] == "endpoint-attachment"

      assert {:ok, %{mode: :auxiliary, relation: "OBSERVED_TO", reason: :projected_observed}} =
               TopologyGraph.classify_projection(normalized)
    end

    test "medium-confidence inferred evidence projects to INFERRED_TO" do
      normalized =
        MapperResultsIngestor.normalize_topology(%{
          "protocol" => "SNMP-L2",
          "local_device_id" => "dev-switch",
          "local_device_ip" => "192.168.1.87",
          "local_if_name" => "1/0/24",
          "local_if_index" => 24,
          "neighbor_mgmt_addr" => "192.168.1.195",
          "neighbor_port_id" => "1/0/1",
          "metadata" => %{
            "source" => "snmp-arp-fdb",
            "confidence_reason" => "port_neighbor_inference",
            "confidence_tier" => "medium",
            "confidence_score" => 66,
            "evidence_class" => "inferred"
          }
        })

      assert {:ok, %{mode: :auxiliary, relation: "INFERRED_TO", reason: :projected_inferred}} =
               TopologyGraph.classify_projection(normalized)
    end

    test "SNMP-L2 medium single-identifier inferred evidence projects to INFERRED_TO" do
      normalized = %{
        "protocol" => "snmp-l2",
        "local_device_id" => "dev-switch",
        "local_device_ip" => "192.168.1.87",
        "local_if_name" => "0/7",
        "local_if_index" => 7,
        "neighbor_mgmt_addr" => "192.168.1.1",
        "metadata" => %{
          "source" => "snmp-l2",
          "confidence_reason" => "single_identifier_inference",
          "confidence_tier" => "medium",
          "confidence_score" => 66,
          "evidence_class" => "inferred"
        }
      }

      assert {:ok, %{mode: :auxiliary, relation: "INFERRED_TO", reason: :projected_inferred}} =
               TopologyGraph.classify_projection(normalized)
    end

    test "wireguard-derived direct evidence projects to backbone CONNECTS_TO" do
      normalized =
        MapperResultsIngestor.normalize_topology(%{
          "protocol" => "wireguard-derived",
          "local_device_id" => "farm01",
          "local_device_ip" => "192.168.1.1",
          "local_if_name" => "wgsts1000",
          "neighbor_device_id" => "tonka01",
          "neighbor_mgmt_addr" => "192.168.1.2",
          "neighbor_port_id" => "wgsts1000",
          "metadata" => %{
            "source" => "wireguard-derived",
            "confidence_tier" => "high",
            "confidence_score" => 95,
            "evidence_class" => "direct"
          }
        })

      assert {:ok, %{mode: :backbone, relation: "CONNECTS_TO", reason: :projected_backbone}} =
               TopologyGraph.classify_projection(normalized)
    end

    test "low-confidence unknown evidence is skipped" do
      normalized =
        MapperResultsIngestor.normalize_topology(%{
          "protocol" => "unknown",
          "local_device_id" => "dev-a",
          "local_device_ip" => "192.168.1.10",
          "neighbor_mgmt_addr" => "192.168.1.11",
          "metadata" => %{}
        })

      assert {:ok, %{mode: :skip, relation: nil, reason: :skip_single_identifier_inference}} =
               TopologyGraph.classify_projection(normalized)
    end

    test "single-identifier inference skip reason is explicit" do
      normalized =
        MapperResultsIngestor.normalize_topology(%{
          "protocol" => "SNMP-L2",
          "local_device_id" => "dev-router",
          "local_device_ip" => "192.168.1.1",
          "local_if_name" => "eth0",
          "neighbor_mgmt_addr" => "192.168.1.77",
          "metadata" => %{
            "source" => "snmp-arp-fdb",
            "confidence_tier" => "low",
            "confidence_score" => 40,
            "confidence_reason" => "single_identifier_inference",
            "evidence_class" => "inferred"
          }
        })

      assert {:ok, %{mode: :skip, reason: :skip_single_identifier_inference}} =
               TopologyGraph.classify_projection(normalized)
    end

    test "competing evidence mix keeps LLDP/CDP backbone and routes SNMP-L2 single-identifier to auxiliary" do
      now = DateTime.truncate(DateTime.utc_now(), :second)

      lldp =
        MapperResultsIngestor.normalize_topology(%{
          "timestamp" => now,
          "protocol" => "lldp",
          "local_device_id" => "dev-a",
          "local_device_ip" => "192.168.1.10",
          "local_if_name" => "eth0",
          "local_if_index" => 10,
          "neighbor_device_id" => "dev-b",
          "neighbor_port_id" => "eth1",
          "metadata" => %{"confidence_tier" => "high", "confidence_score" => 95}
        })

      cdp =
        MapperResultsIngestor.normalize_topology(%{
          "timestamp" => now,
          "protocol" => "cdp",
          "local_device_id" => "dev-a",
          "local_device_ip" => "192.168.1.10",
          "local_if_name" => "eth0",
          "local_if_index" => 10,
          "neighbor_device_id" => "dev-b",
          "neighbor_port_id" => "eth1",
          "metadata" => %{"confidence_tier" => "medium", "confidence_score" => 80}
        })

      snmp_l2_single_identifier =
        MapperResultsIngestor.normalize_topology(%{
          "timestamp" => now,
          "protocol" => "snmp-l2",
          "local_device_id" => "dev-a",
          "local_device_ip" => "192.168.1.10",
          "local_if_name" => "eth0",
          "local_if_index" => 10,
          "neighbor_device_id" => "dev-b",
          "neighbor_port_id" => "eth9",
          "metadata" => %{
            "confidence_tier" => "medium",
            "confidence_score" => 70,
            "confidence_reason" => "port_neighbor_inference",
            "evidence_class" => "inferred"
          }
        })

      unifi_direct =
        MapperResultsIngestor.normalize_topology(%{
          "timestamp" => now,
          "protocol" => "unifi-api",
          "local_device_id" => "dev-a",
          "local_device_ip" => "192.168.1.10",
          "local_if_name" => "eth0",
          "local_if_index" => 10,
          "neighbor_device_id" => "dev-b",
          "neighbor_port_id" => "eth1",
          "metadata" => %{"confidence_tier" => "medium", "confidence_score" => 78}
        })

      assert {:ok, %{mode: :backbone, relation: "CONNECTS_TO"}} =
               TopologyGraph.classify_projection(lldp)

      assert {:ok, %{mode: :backbone, relation: "CONNECTS_TO"}} =
               TopologyGraph.classify_projection(cdp)

      assert {:ok, %{mode: :auxiliary, relation: "INFERRED_TO"}} =
               TopologyGraph.classify_projection(snmp_l2_single_identifier)

      assert {:ok, %{mode: :backbone, relation: "CONNECTS_TO"}} =
               TopologyGraph.classify_projection(unifi_direct)

      diagnostics =
        TopologyGraph.projection_diagnostics([
          lldp,
          cdp,
          snmp_l2_single_identifier,
          unifi_direct
        ])

      assert diagnostics.total == 4
      assert diagnostics.accepted["projected_backbone"] == 3
      assert diagnostics.accepted["projected_inferred"] == 1
    end
  end

  describe "projection_diagnostics/1 contract" do
    test "aggregates accepted and rejected reasons with explicit keys" do
      accepted_link =
        MapperResultsIngestor.normalize_topology(%{
          "protocol" => "LLDP",
          "local_device_id" => "dev-a",
          "local_device_ip" => "192.168.1.87",
          "local_if_index" => 7,
          "local_if_name" => "sfp+7",
          "neighbor_device_id" => "dev-b",
          "neighbor_port_id" => "sfp+1",
          "neighbor_mgmt_addr" => "192.168.1.138"
        })

      rejected_link =
        MapperResultsIngestor.normalize_topology(%{
          "protocol" => "LLDP",
          "local_device_id" => "dev-a",
          "local_device_ip" => "192.168.1.87",
          "local_if_index" => nil,
          "local_if_name" => "sfp+7",
          "neighbor_device_id" => "dev-c",
          "neighbor_port_id" => "sfp+2",
          "neighbor_mgmt_addr" => "192.168.1.139"
        })

      missing_ids_link = %{"protocol" => "LLDP"}

      diagnostics =
        TopologyGraph.projection_diagnostics([accepted_link, rejected_link, missing_ids_link])

      assert diagnostics.total == 3
      assert diagnostics.accepted["projected_backbone"] == 2
      assert diagnostics.rejected["missing_ids"] == 1
    end
  end

  describe "pruning policy gates" do
    test "stale projected-link pruning is disabled by default" do
      assert TopologyGraph.prune_stale_projected_links_enabled?() == false
    end
  end

  describe "canonical rebuild query contract" do
    test "mapper upsert queries preserve local-side device ip identity" do
      payload = %{
        local_device_id: "sr:ap-a",
        local_device_ip: "192.168.1.200",
        neighbor_device_id: "sr:endpoint-a",
        local_interface_id: "sr:ap-a/wifi0",
        neighbor_interface_id: "sr:endpoint-a/unknown",
        protocol: "snmp-l2",
        local_if_name: "wifi0",
        local_if_index: 10,
        neighbor_port_name: "unknown",
        neighbor_name: nil,
        neighbor_ip: "192.168.1.62",
        evidence_class: "endpoint-attachment",
        confidence_tier: "low",
        confidence_score: 40,
        confidence_reason: "single_identifier_inference",
        observed_at: "2026-03-24T04:45:00Z"
      }

      backbone_query = TopologyGraph.backbone_link_upsert_query(payload)
      auxiliary_query = TopologyGraph.auxiliary_link_upsert_query(payload, "ATTACHED_TO")

      assert backbone_query =~ "SET a.ip = '192.168.1.200'"
      assert backbone_query =~ "SET b.ip = '192.168.1.62'"
      assert auxiliary_query =~ "SET a.ip = '192.168.1.200'"
      assert auxiliary_query =~ "SET b.ip = '192.168.1.62'"
    end

    test "upsert query keeps canonical relation syntax stable" do
      query = TopologyGraph.canonical_rebuild_upsert_query("2026-02-25T00:00:00Z")

      assert query =~ "MERGE (a)-[cr:CANONICAL_TOPOLOGY]->(b)"
      refute query =~ "CNONICAL_TOPOLOGY"
      refute query =~ "[]->"
      assert query =~ "WITH src_id, dst_id, collect({"
      assert query =~ "UNWIND candidates AS c"
      assert query =~ "support_rank"
      assert query =~ "pair_support_rank"
      assert query =~ "type(r) IN ['CONNECTS_TO', 'INFERRED_TO', 'ATTACHED_TO']"
      refute query =~ "type(r) IN ['CONNECTS_TO', 'INFERRED_TO', 'ATTACHED_TO', 'OBSERVED_TO']"
      assert query =~ "AND ai.device_id STARTS WITH 'sr:'"
      assert query =~ "AND bi.device_id STARTS WITH 'sr:'"
      assert query =~ "toLower(trim(ai.device_id)) <> 'nil'"
      assert query =~ "toLower(trim(ai.device_id)) <> 'null'"
      assert query =~ "toLower(trim(ai.device_id)) <> 'undefined'"
      assert query =~ "toLower(trim(bi.device_id)) <> 'nil'"
      assert query =~ "toLower(trim(bi.device_id)) <> 'null'"
      assert query =~ "toLower(trim(bi.device_id)) <> 'undefined'"
      assert query =~ "best_local_if_index"
      assert query =~ "best_neighbor_if_index"
      assert query =~ "SET cr.local_if_index ="
      assert query =~ "SET cr.neighbor_if_index ="
      assert query =~ "SET cr.local_if_index_ab = cr.local_if_index"
      assert query =~ "SET cr.local_if_index_ba = cr.neighbor_if_index"
      assert query =~ "SET cr.local_if_name_ab = cr.local_if_name"
      assert query =~ "SET cr.local_if_name_ba = cr.neighbor_if_name"
      assert query =~ "SET cr.flow_pps = coalesce(cr.flow_pps, 0)"
      assert query =~ "SET cr.flow_bps = coalesce(cr.flow_bps, 0)"
      assert query =~ "SET cr.capacity_bps = coalesce(cr.capacity_bps, 0)"
      assert query =~ "SET cr.flow_pps_ab = coalesce(cr.flow_pps_ab, 0)"
      assert query =~ "SET cr.flow_pps_ba = coalesce(cr.flow_pps_ba, 0)"
      assert query =~ "SET cr.flow_bps_ab = coalesce(cr.flow_bps_ab, 0)"
      assert query =~ "SET cr.flow_bps_ba = coalesce(cr.flow_bps_ba, 0)"
      assert query =~ "SET cr.telemetry_eligible = coalesce(cr.telemetry_eligible, false)"
      assert query =~ "SET cr.telemetry_source = coalesce(cr.telemetry_source, 'none')"
      assert query =~ "SET cr.telemetry_observed_at = coalesce(cr.telemetry_observed_at, '')"
    end

    test "prune query targets canonical topology edges" do
      query = TopologyGraph.canonical_rebuild_prune_query("2026-02-25T00:00:00Z")

      assert query =~ "MATCH ()-[r:CANONICAL_TOPOLOGY]->()"
      assert query =~ "DELETE r"
    end

    test "canonical edge count query targets canonical topology edges" do
      query = TopologyGraph.canonical_edge_count_query()

      assert query =~ "MATCH ()-[r:CANONICAL_TOPOLOGY]->()"
      assert query =~ "RETURN {count: count(r)}"
    end

    test "mapper evidence count query targets mapper topology evidence edges" do
      query = TopologyGraph.mapper_evidence_edge_count_query()

      assert query =~ "r.ingestor = 'mapper_topology_v1'"
      assert query =~ "type(r) IN ['CONNECTS_TO', 'INFERRED_TO', 'ATTACHED_TO']"
      assert query =~ "RETURN {count: count(r)}"
    end

    test "canonical telemetry batch query updates multiple edges in one UNWIND" do
      query =
        TopologyGraph.canonical_edge_telemetry_batch_query([
          %{
            src_id: "sr:a",
            dst_id: "sr:b",
            flow_pps: 12,
            flow_bps: 1200,
            capacity_bps: 1_000_000,
            flow_pps_ab: 7,
            flow_pps_ba: 5,
            flow_bps_ab: 700,
            flow_bps_ba: 500,
            telemetry_eligible: true,
            telemetry_source: "interface",
            telemetry_observed_at: "2026-03-22T18:44:48Z"
          },
          %{
            src_id: "sr:c",
            dst_id: "sr:d",
            flow_pps: 0,
            flow_bps: 0,
            capacity_bps: 0,
            flow_pps_ab: 0,
            flow_pps_ba: 0,
            flow_bps_ab: 0,
            flow_bps_ba: 0,
            telemetry_eligible: false,
            telemetry_source: "none",
            telemetry_observed_at: "2026-03-22T18:44:48Z"
          }
        ])

      assert query =~ "UNWIND ["

      assert query =~
               "MATCH (a:Device {id: row.src_id})-[r:CANONICAL_TOPOLOGY]->(b:Device {id: row.dst_id})"

      assert query =~ "WHERE r.ingestor = 'mapper_topology_v1'"
      assert query =~ "SET r.flow_pps = row.flow_pps"
      assert query =~ "SET r.telemetry_source = row.telemetry_source"
      assert query =~ "src_id: 'sr:a'"
      assert query =~ "dst_id: 'sr:d'"
      assert query =~ "telemetry_eligible: true"
      assert query =~ "telemetry_eligible: false"
    end

    test "canonical rebuild telemetry emits before/after counters on completion" do
      handler_id = "canonical-rebuild-completed-#{System.unique_integer([:positive])}"

      :ok =
        :telemetry.attach(
          handler_id,
          [:serviceradar, :topology, :canonical_rebuild, :completed],
          fn event, measurements, metadata, pid ->
            send(pid, {:telemetry, event, measurements, metadata})
          end,
          self()
        )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      stats = %{
        before_edges: 7,
        mapper_evidence_edges: 12,
        after_upsert_edges: 10,
        after_prune_edges: 9,
        stale_cutoff: "2026-02-26T00:00:00Z"
      }

      assert :ok = TopologyGraph.emit_canonical_rebuild_telemetry(:completed, stats)

      assert_receive {:telemetry, [:serviceradar, :topology, :canonical_rebuild, :completed],
                      measurements, metadata}

      assert measurements.before_edges == 7
      assert measurements.mapper_evidence_edges == 12
      assert measurements.after_upsert_edges == 10
      assert measurements.after_prune_edges == 9
      assert metadata.status == :completed
    end
  end

  describe "canonical rebuild stabilization" do
    test "self_heal_needed?/3 gates only on low canonical count with mapper evidence present" do
      assert TopologyGraph.self_heal_needed?(0, 5, 1)
      refute TopologyGraph.self_heal_needed?(2, 5, 1)
      refute TopologyGraph.self_heal_needed?(0, 0, 1)
    end

    test "canonical_rebuild_min_edges/0 defaults to 1 and honors positive config" do
      original = Application.get_env(:serviceradar_core, TopologyGraph, [])

      on_exit(fn ->
        Application.put_env(:serviceradar_core, TopologyGraph, original)
      end)

      Application.put_env(:serviceradar_core, TopologyGraph, [])
      assert TopologyGraph.canonical_rebuild_min_edges() == 1

      Application.put_env(:serviceradar_core, TopologyGraph, min_canonical_edges: 3)
      assert TopologyGraph.canonical_rebuild_min_edges() == 3
    end

    test "canonical rebuild timeout and telemetry batch size honor positive config" do
      original = Application.get_env(:serviceradar_core, TopologyGraph, [])

      on_exit(fn ->
        Application.put_env(:serviceradar_core, TopologyGraph, original)
      end)

      Application.put_env(:serviceradar_core, TopologyGraph, [])
      assert TopologyGraph.canonical_rebuild_timeout_ms() == 60_000
      assert TopologyGraph.canonical_edge_telemetry_batch_size() == 100

      Application.put_env(
        :serviceradar_core,
        TopologyGraph,
        canonical_rebuild_timeout_ms: 90_000,
        canonical_edge_telemetry_batch_size: 250
      )

      assert TopologyGraph.canonical_rebuild_timeout_ms() == 90_000
      assert TopologyGraph.canonical_edge_telemetry_batch_size() == 250
    end
  end

  describe "render readiness contract" do
    test "classifies fully-attributed canonical edge as render_ready" do
      edge = %{local_if_index_ab: 7, local_if_index_ba: 25}
      assert TopologyGraph.edge_render_readiness_class(edge) == :render_ready
    end

    test "classifies one-sided canonical edge as render_partial" do
      edge = %{local_if_index_ab: 7, local_if_index_ba: 0}
      assert TopologyGraph.edge_render_readiness_class(edge) == :render_partial
    end

    test "classifies unattributed canonical edge as render_unattributed" do
      edge = %{local_if_index_ab: 0, local_if_index_ba: nil, local_if_index: nil}
      assert TopologyGraph.edge_render_readiness_class(edge) == :render_unattributed
    end
  end
end
