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
          "neighbor_device_id" => "sr:dev-b",
          "neighbor_port_id" => "sfp+1",
          "neighbor_mgmt_addr" => "192.168.1.138",
          "metadata" => %{"source" => "snmp-lldp"}
        })

      assert {:ok, %{mode: :backbone, relation: "CONNECTS_TO", reason: :projected_backbone}} =
               TopologyGraph.classify_projection(normalized)
    end

    test "SNMP ARP/FDB single-identifier evidence stays observation-only" do
      normalized =
        %{
          "protocol" => "SNMP-L2",
          "local_device_id" => "dev-router",
          "local_device_ip" => "192.168.1.1",
          "local_if_name" => "eth0",
          "neighbor_mgmt_addr" => "192.168.1.77",
          "metadata" => %{
            "source" => "snmp-arp-fdb",
            "evidence" => "ipNetToMedia+dot1dTpFdb"
          }
        }
        |> MapperResultsIngestor.normalize_topology()
        # Simulate the post-resolution/promotion shape: the neighbor resolved
        # to a canonical sr: identity, while the single-identifier confidence
        # classification derived at normalize time is preserved.
        |> Map.put(:neighbor_device_id, "sr:host-77")

      assert normalized.metadata["confidence_reason"] == "single_identifier_inference"
      assert normalized.metadata["evidence_class"] == "observed-only"
      assert normalized.metadata["relation_family"] == "OBSERVED_TO"

      assert {:ok, %{mode: :auxiliary, relation: "OBSERVED_TO", reason: :projected_observed}} =
               TopologyGraph.classify_projection(normalized)
    end

    test "SNMP ARP/FDB mapper confidence is preserved when provided" do
      normalized =
        MapperResultsIngestor.normalize_topology(%{
          "protocol" => "SNMP-L2",
          "local_device_id" => "dev-switch",
          "local_device_ip" => "192.168.1.87",
          "local_if_name" => "1/0/24",
          "local_if_index" => 24,
          "neighbor_device_id" => "sr:host-195",
          "neighbor_mgmt_addr" => "192.168.1.195",
          "metadata" => %{
            "source" => "snmp-arp-fdb",
            "evidence" => "ipNetToMedia+dot1dTpFdb",
            "confidence_tier" => "medium",
            "confidence_score" => 72,
            "confidence_reason" => "arp_fdb_port_mapping",
            "evidence_class" => "inferred"
          }
        })

      assert normalized.metadata["confidence_tier"] == "medium"
      assert normalized.metadata["confidence_score"] == 72
      assert normalized.metadata["confidence_reason"] == "arp_fdb_port_mapping"
      assert normalized.metadata["evidence_class"] == "inferred-segment"
      assert normalized.metadata["relation_family"] == "INFERRED_TO"

      assert {:ok, %{mode: :auxiliary, relation: "INFERRED_TO", reason: :projected_inferred}} =
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
          "neighbor_device_id" => "sr:host-195",
          "neighbor_mgmt_addr" => "192.168.1.195",
          "neighbor_port_id" => "1/0/1",
          "metadata" => %{
            "source" => "snmp-arp-fdb",
            "confidence_reason" => "port_neighbor_inference",
            "confidence_tier" => "medium",
            "confidence_score" => 66,
            "evidence_class" => "inferred-segment"
          }
        })

      assert {:ok, %{mode: :auxiliary, relation: "INFERRED_TO", reason: :projected_inferred}} =
               TopologyGraph.classify_projection(normalized)
    end

    test "low-confidence inferred evidence is filtered from projection" do
      normalized =
        MapperResultsIngestor.normalize_topology(%{
          "protocol" => "SNMP-L2",
          "local_device_id" => "dev-switch",
          "local_device_ip" => "192.168.1.87",
          "local_if_name" => "1/0/24",
          "local_if_index" => 24,
          "neighbor_device_id" => "sr:host-195",
          "neighbor_mgmt_addr" => "192.168.1.195",
          "neighbor_port_id" => "1/0/1",
          "metadata" => %{
            "source" => "snmp-arp-fdb",
            "confidence_reason" => "unspecified",
            "confidence_tier" => "low",
            "confidence_score" => 40,
            "evidence_class" => "inferred-segment"
          }
        })

      assert {:ok, %{mode: :skip, relation: nil, reason: :skip_inferred_low_confidence}} =
               TopologyGraph.classify_projection(normalized)
    end

    test "SNMP-L2 medium single-identifier inferred evidence projects to OBSERVED_TO" do
      normalized = %{
        "protocol" => "snmp-l2",
        "local_device_id" => "dev-switch",
        "local_device_ip" => "192.168.1.87",
        "local_if_name" => "0/7",
        "local_if_index" => 7,
        "neighbor_device_id" => "sr:host-gw",
        "neighbor_mgmt_addr" => "192.168.1.1",
        "metadata" => %{
          "source" => "snmp-l2",
          "confidence_reason" => "single_identifier_inference",
          "confidence_tier" => "medium",
          "confidence_score" => 66,
          "evidence_class" => "inferred-segment"
        }
      }

      assert {:ok, %{mode: :auxiliary, relation: "OBSERVED_TO", reason: :projected_observed}} =
               TopologyGraph.classify_projection(normalized)
    end

    test "wireguard-derived direct evidence projects to logical peer relation" do
      normalized =
        MapperResultsIngestor.normalize_topology(%{
          "protocol" => "wireguard-derived",
          "local_device_id" => "farm01",
          "local_device_ip" => "192.168.1.1",
          "local_if_name" => "wgsts1000",
          "neighbor_device_id" => "sr:tonka01",
          "neighbor_mgmt_addr" => "192.168.1.2",
          "neighbor_port_id" => "wgsts1000",
          "metadata" => %{
            "source" => "wireguard-derived",
            "confidence_tier" => "high",
            "confidence_score" => 95,
            "evidence_class" => "direct-logical"
          }
        })

      assert normalized.metadata["relation_family"] == "LOGICAL_PEER"

      assert {:ok, %{mode: :auxiliary, relation: "LOGICAL_PEER", reason: :projected_logical}} =
               TopologyGraph.classify_projection(normalized)
    end

    test "hosted virtual evidence projects to HOSTED_ON" do
      normalized =
        MapperResultsIngestor.normalize_topology(%{
          "protocol" => "proxmox-api",
          "local_device_id" => "host-a",
          "local_device_ip" => "192.0.2.10",
          "local_if_name" => "vmbr0",
          "neighbor_device_id" => "sr:guest-a",
          "neighbor_mgmt_addr" => "192.168.2.197",
          "metadata" => %{
            "source" => "proxmox-api",
            "confidence_tier" => "high",
            "confidence_score" => 90,
            "evidence_class" => "hosted-virtual"
          }
        })

      assert normalized.metadata["relation_family"] == "HOSTED_ON"

      assert {:ok, %{mode: :auxiliary, relation: "HOSTED_ON", reason: :projected_hosted}} =
               TopologyGraph.classify_projection(normalized)
    end

    test "low-confidence unknown evidence is skipped" do
      normalized =
        MapperResultsIngestor.normalize_topology(%{
          "protocol" => "unknown",
          "local_device_id" => "dev-a",
          "local_device_ip" => "192.168.1.10",
          "neighbor_device_id" => "sr:host-11",
          "neighbor_mgmt_addr" => "192.168.1.11",
          "metadata" => %{}
        })

      assert {:ok, %{mode: :skip, relation: nil, reason: :skip_single_identifier_inference}} =
               TopologyGraph.classify_projection(normalized)
    end

    test "single-identifier inference normalizes to observation-only relation" do
      normalized =
        MapperResultsIngestor.normalize_topology(%{
          "protocol" => "SNMP-L2",
          "local_device_id" => "dev-router",
          "local_device_ip" => "192.168.1.1",
          "local_if_name" => "eth0",
          "neighbor_device_id" => "sr:host-77",
          "neighbor_mgmt_addr" => "192.168.1.77",
          "metadata" => %{
            "source" => "snmp-arp-fdb",
            "confidence_tier" => "low",
            "confidence_score" => 40,
            "confidence_reason" => "single_identifier_inference",
            "evidence_class" => "inferred-segment"
          }
        })

      assert normalized.metadata["relation_family"] == "OBSERVED_TO"

      assert {:ok, %{mode: :auxiliary, relation: "OBSERVED_TO", reason: :projected_observed}} =
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
          "neighbor_device_id" => "sr:dev-b",
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
          "neighbor_device_id" => "sr:dev-b",
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
          "neighbor_device_id" => "sr:dev-b",
          "neighbor_port_id" => "eth9",
          "metadata" => %{
            "confidence_tier" => "medium",
            "confidence_score" => 70,
            "confidence_reason" => "port_neighbor_inference",
            "evidence_class" => "inferred-segment"
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
          "neighbor_device_id" => "sr:dev-b",
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

  describe "resolved SNMP FDB enrichment" do
    test "neighbors with strong direct topology evidence stay inferred" do
      [enriched] =
        [
          %{
            protocol: "SNMP-L2",
            local_device_id: "sr:switch-a",
            local_device_ip: "192.168.1.87",
            local_if_name: "1/0/24",
            local_if_index: 24,
            neighbor_device_id: "sr:neighbor-a",
            neighbor_mgmt_addr: "192.168.1.195",
            metadata: %{
              "source" => "snmp-arp-fdb",
              "confidence_tier" => "medium",
              "confidence_score" => 72,
              "confidence_reason" => "arp_fdb_port_mapping",
              "evidence_class" => "inferred-segment"
            }
          },
          %{
            protocol: "LLDP",
            local_device_id: "sr:neighbor-a",
            local_device_ip: "192.168.1.195",
            local_if_name: "eth1",
            local_if_index: 1,
            neighbor_device_id: "sr:core-a",
            neighbor_mgmt_addr: "192.168.1.1",
            neighbor_port_id: "eth2",
            metadata: %{
              "source" => "lldp",
              "confidence_tier" => "high",
              "confidence_score" => 95,
              "confidence_reason" => "direct_lldp_neighbor",
              "evidence_class" => "direct-physical"
            }
          }
        ]
        |> MapperResultsIngestor.enrich_resolved_topology_records(%{
          "sr:neighbor-a" => %{
            uid: "sr:neighbor-a",
            type: nil,
            type_id: 0,
            name: nil,
            hostname: nil,
            metadata: %{
              "identity_source" => "mapper_topology_sighting",
              "identity_state" => "provisional"
            }
          }
        })
        |> List.wrap()
        |> Enum.take(1)

      assert enriched.metadata["evidence_class"] == "inferred-segment"
      assert enriched.metadata["relation_family"] == "INFERRED_TO"

      assert {:ok, %{mode: :auxiliary, relation: "INFERRED_TO", reason: :projected_inferred}} =
               TopologyGraph.classify_projection(enriched)
    end

    test "provisional topology-sighting neighbors become attachment evidence" do
      [enriched] =
        MapperResultsIngestor.enrich_resolved_topology_records(
          [
            %{
              protocol: "SNMP-L2",
              local_device_id: "sr:switch-a",
              local_device_ip: "192.168.1.87",
              local_if_name: "1/0/24",
              local_if_index: 24,
              neighbor_device_id: "sr:endpoint-a",
              neighbor_mgmt_addr: "192.168.1.62",
              metadata: %{
                "source" => "snmp-arp-fdb",
                "confidence_tier" => "medium",
                "confidence_score" => 72,
                "confidence_reason" => "arp_fdb_port_mapping",
                "evidence_class" => "inferred-segment"
              }
            }
          ],
          %{
            "sr:endpoint-a" => %{
              uid: "sr:endpoint-a",
              type: nil,
              type_id: 0,
              name: nil,
              hostname: nil,
              metadata: %{
                "identity_source" => "mapper_topology_sighting",
                "identity_state" => "provisional"
              }
            }
          }
        )

      assert enriched.metadata["evidence_class"] == "inferred-segment"
      assert enriched.metadata["relation_family"] == "ATTACHED_TO"
      assert enriched.metadata["confidence_reason"] == "arp_fdb_port_mapping"

      assert {:ok, %{mode: :auxiliary, relation: "ATTACHED_TO", reason: :projected_attachment}} =
               TopologyGraph.classify_projection(enriched)
    end

    test "managed infrastructure neighbors stay inferred" do
      [enriched] =
        MapperResultsIngestor.enrich_resolved_topology_records(
          [
            %{
              protocol: "SNMP-L2",
              local_device_id: "sr:switch-a",
              local_device_ip: "192.168.1.87",
              local_if_name: "1/0/24",
              local_if_index: 24,
              neighbor_device_id: "sr:switch-b",
              neighbor_mgmt_addr: "192.168.1.195",
              metadata: %{
                "source" => "snmp-arp-fdb",
                "confidence_tier" => "medium",
                "confidence_score" => 72,
                "confidence_reason" => "arp_fdb_port_mapping",
                "evidence_class" => "inferred-segment"
              }
            }
          ],
          %{
            "sr:switch-b" => %{
              uid: "sr:switch-b",
              type: "Switch",
              type_id: 10,
              name: "USWPro24",
              hostname: "USWPro24",
              metadata: %{}
            }
          }
        )

      assert enriched.metadata["evidence_class"] == "inferred-segment"
      assert enriched.metadata["relation_family"] == "INFERRED_TO"

      assert {:ok, %{mode: :auxiliary, relation: "INFERRED_TO", reason: :projected_inferred}} =
               TopologyGraph.classify_projection(enriched)
    end

    test "LLDP neighbors resolved to provisional endpoint candidates become attachment evidence" do
      [enriched] =
        MapperResultsIngestor.enrich_resolved_topology_records(
          [
            %{
              protocol: "LLDP",
              local_device_id: "sr:switch-a",
              local_device_ip: "192.168.1.87",
              local_if_name: "1/0/7",
              local_if_index: 7,
              neighbor_device_id: "sr:endpoint-b",
              neighbor_chassis_id: "aa:bb:cc:dd:ee:07",
              metadata: %{
                "source" => "lldp",
                "confidence_tier" => "high",
                "confidence_score" => 95,
                "confidence_reason" => "direct_lldp_neighbor",
                "evidence_class" => "direct-physical",
                "relation_family" => "CONNECTS_TO"
              }
            }
          ],
          %{
            "sr:endpoint-b" => %{
              uid: "sr:endpoint-b",
              type: nil,
              type_id: 0,
              name: nil,
              hostname: nil,
              metadata: %{
                "identity_source" => "mapper_topology_sighting",
                "identity_state" => "provisional"
              }
            }
          }
        )

      assert enriched.metadata["relation_family"] == "ATTACHED_TO"
      assert enriched.metadata["evidence_class"] == "direct-physical"
    end

    test "LLDP neighbors resolved to infrastructure keep CONNECTS_TO backbone semantics" do
      [enriched] =
        MapperResultsIngestor.enrich_resolved_topology_records(
          [
            %{
              protocol: "LLDP",
              local_device_id: "sr:switch-a",
              local_device_ip: "192.168.1.87",
              local_if_name: "1/0/24",
              local_if_index: 24,
              neighbor_device_id: "sr:core-b",
              neighbor_port_id: "eth2",
              metadata: %{
                "source" => "lldp",
                "confidence_tier" => "high",
                "confidence_score" => 95,
                "confidence_reason" => "direct_lldp_neighbor",
                "evidence_class" => "direct-physical",
                "relation_family" => "CONNECTS_TO"
              }
            }
          ],
          %{
            "sr:core-b" => %{
              uid: "sr:core-b",
              type: "Switch",
              type_id: 10,
              name: "core-b",
              hostname: "core-b",
              metadata: %{}
            }
          }
        )

      assert enriched.metadata["relation_family"] == "CONNECTS_TO"
      assert enriched.metadata["evidence_class"] == "direct-physical"
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
          "neighbor_device_id" => "sr:dev-b",
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
          "neighbor_device_id" => "sr:dev-c",
          "neighbor_port_id" => "sfp+2",
          "neighbor_mgmt_addr" => "192.168.1.139"
        })

      missing_ids_link = %{"protocol" => "LLDP"}

      diagnostics =
        TopologyGraph.projection_diagnostics([accepted_link, rejected_link, missing_ids_link])

      assert diagnostics.total == 3
      assert diagnostics.accepted["projected_backbone"] == 2
      assert diagnostics.rejected["missing_local_id"] == 1
    end
  end

  describe "pruning policy gates" do
    test "stale projected-link pruning is ENABLED by default" do
      # Flipped deliberately. Shipped off, a topology edge was asserted as
      # current forever: one deployment served 14-day-old links from a discovery
      # job that had been deleted, and an operator's only recourse was a manual
      # purge of the graph.
      #
      # A topology edge is a claim about how the network is wired NOW, and the
      # only thing keeping it true is re-observation. Off-by-default made the
      # map state its last known guess with no expiry.
      #
      # Safe to default on because the window is derived from the discovery
      # interval rather than a wall clock -- see
      # TopologyGraph.Utils.derive_stale_minutes/2. An operator can still pin a
      # fixed window with :mapper_topology_edge_stale_minutes, or set the flag
      # to false outright.
      assert TopologyGraph.prune_stale_projected_links_enabled?() == true
    end

    test "an explicit false still disables it" do
      Application.put_env(
        :serviceradar_core,
        :mapper_topology_prune_stale_projected_links_enabled,
        false
      )

      on_exit(fn ->
        Application.delete_env(
          :serviceradar_core,
          :mapper_topology_prune_stale_projected_links_enabled
        )
      end)

      refute TopologyGraph.prune_stale_projected_links_enabled?()
    end
  end

  describe "canonical rebuild query contract" do
    test "endpoint inventory risk summary query is bounded to device scalar properties" do
      query =
        TopologyGraph.endpoint_inventory_risk_summary_query("sr:device-risk", %{
          pkg_worst_severity: "critical",
          pkg_critical_count: 2,
          pkg_kev_count: 1,
          pkg_has_unpatched_rce: true,
          pkg_risk_summary_at: "2026-06-02T12:00:00Z"
        })

      assert TopologyGraph.endpoint_inventory_risk_summary_fields() == [
               :pkg_worst_severity,
               :pkg_critical_count,
               :pkg_kev_count,
               :pkg_has_unpatched_rce,
               :pkg_risk_summary_at
             ]

      assert query =~ "MERGE (d:Device {id: 'sr:device-risk'})"
      assert query =~ "SET d.pkg_worst_severity = 'critical'"
      assert query =~ "SET d.pkg_critical_count = 2"
      assert query =~ "SET d.pkg_kev_count = 1"
      assert query =~ "SET d.pkg_has_unpatched_rce = true"
      assert query =~ "SET d.pkg_risk_summary_at = '2026-06-02T12:00:00Z'"
      assert length(Regex.scan(~r/SET d\.pkg_/, query)) == 5

      refute query =~ "Package"
      refute query =~ "HAS_PACKAGE"
      refute query =~ "AFFECTED_BY"
      refute query =~ "CREATE"
      refute query =~ "]-"
      refute query =~ "->"
    end

    test "endpoint inventory risk summary query clears absent advisory scoring to unknown defaults" do
      query = TopologyGraph.endpoint_inventory_risk_summary_query("sr:device-risk", %{})

      assert query =~ "SET d.pkg_worst_severity = 'unknown'"
      assert query =~ "SET d.pkg_critical_count = 0"
      assert query =~ "SET d.pkg_kev_count = 0"
      assert query =~ "SET d.pkg_has_unpatched_rce = false"
      assert length(Regex.scan(~r/SET d\.pkg_/, query)) == 5

      refute query =~ "Package"
      refute query =~ "HAS_PACKAGE"
      refute query =~ "AFFECTED_BY"
    end

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
        evidence_class: "inferred-segment",
        relation_family: "ATTACHED_TO",
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

      assert query =~ "MERGE (a)-[cr:CANONICAL_TOPOLOGY {link_key: link_key}]->(b)"
      refute query =~ "CNONICAL_TOPOLOGY"
      refute query =~ "[]->"

      assert query =~
               "WITH src_id, dst_id, local_interface_key + '|' + neighbor_interface_key AS link_key, collect({"

      assert query =~ "WITH src_id, dst_id, link_key, head(candidates) AS best, candidates"
      assert query =~ "UNWIND candidates AS c"
      assert query =~ "support_rank"
      assert query =~ "pair_support_rank"
      assert query =~ "SET cr += {"
      assert query =~ "link_key: link_key,"

      assert query =~
               "type(r) IN ['CONNECTS_TO', 'LOGICAL_PEER', 'HOSTED_ON', 'INFERRED_TO', 'ATTACHED_TO']"

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
      assert query =~ "local_if_index: local_if_index,"
      assert query =~ "neighbor_if_index: neighbor_if_index,"
      assert query =~ "local_if_index_ab: local_if_index,"
      assert query =~ "local_if_index_ba: neighbor_if_index,"
      assert query =~ "local_if_name_ab: local_if_name,"
      assert query =~ "local_if_name_ba: neighbor_if_name,"
      assert query =~ "flow_pps: coalesce(cr.flow_pps, 0),"
      assert query =~ "flow_bps: coalesce(cr.flow_bps, 0),"
      assert query =~ "capacity_bps: coalesce(cr.capacity_bps, 0),"
      assert query =~ "flow_pps_ab: coalesce(cr.flow_pps_ab, 0),"
      assert query =~ "flow_pps_ba: coalesce(cr.flow_pps_ba, 0),"
      assert query =~ "flow_bps_ab: coalesce(cr.flow_bps_ab, 0),"
      assert query =~ "flow_bps_ba: coalesce(cr.flow_bps_ba, 0),"
      assert query =~ "telemetry_eligible: coalesce(cr.telemetry_eligible, false),"
      assert query =~ "telemetry_source: coalesce(cr.telemetry_source, 'none'),"
      assert query =~ "telemetry_observed_at: coalesce(cr.telemetry_observed_at, ''),"
    end

    test "unseen projected link prune deletes reverse mapper edge before forward edge" do
      [reverse_query, forward_query] =
        TopologyGraph.prune_unseen_projected_links_queries(
          "sr:device-a",
          MapSet.new(["sr:device-b"])
        )

      assert reverse_query =~ "MATCH (a:Interface)-[r:CONNECTS_TO]->(b:Interface)"
      assert reverse_query =~ "a.device_id = 'sr:device-a'"
      assert reverse_query =~ "NOT b.device_id IN ['sr:device-b']"
      assert reverse_query =~ "MATCH (b)-[rr:CONNECTS_TO]->(a)"
      assert reverse_query =~ "DELETE rr"

      assert forward_query =~ "MATCH (a:Interface)-[r:CONNECTS_TO]->(b:Interface)"
      assert forward_query =~ "a.device_id = 'sr:device-a'"
      assert forward_query =~ "NOT b.device_id IN ['sr:device-b']"
      assert forward_query =~ "DELETE r"
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

      assert query =~
               "type(r) IN ['CONNECTS_TO', 'LOGICAL_PEER', 'HOSTED_ON', 'INFERRED_TO', 'ATTACHED_TO', 'OBSERVED_TO']"

      assert query =~ "RETURN {count: count(r)}"
    end

    test "stale mapper evidence prune query includes observation-only edges" do
      query = TopologyGraph.prune_stale_mapper_evidence_links_query("2026-02-25T00:00:00Z")

      assert query =~ "r.ingestor = 'mapper_topology_v1'"

      assert query =~
               "type(r) IN ['CONNECTS_TO', 'LOGICAL_PEER', 'HOSTED_ON', 'INFERRED_TO', 'ATTACHED_TO', 'OBSERVED_TO']"

      assert query =~ "DELETE r"
    end

    # The upsert and the evidence prune have to agree about a missing timestamp,
    # or an edge can be permanently unprunable AND permanently projected. The
    # upsert used to admit `last_observed_at IS NULL` unconditionally while the
    # prune required `IS NOT NULL`, so an evidence edge with no last_observed_at
    # was re-projected on every rebuild and could never be deleted. Both sides now
    # use the same coalesce the projection already uses for the emitted value.
    test "upsert query does not admit evidence with no usable timestamp" do
      query = TopologyGraph.canonical_rebuild_upsert_query("2026-02-25T00:00:00Z")

      assert query =~
               "coalesce(r.last_observed_at, r.observed_at) >= '2026-02-25T00:00:00Z'"

      refute query =~ "r.last_observed_at IS NULL OR"
    end

    test "evidence prune deletes edges that carry no usable timestamp" do
      query = TopologyGraph.prune_stale_mapper_evidence_links_query("2026-02-25T00:00:00Z")

      assert query =~ "coalesce(r.last_observed_at, r.observed_at) IS NULL"

      assert query =~
               "coalesce(r.last_observed_at, r.observed_at) < '2026-02-25T00:00:00Z'"

      refute query =~ "r.last_observed_at IS NOT NULL"
    end

    test "upsert and evidence prune partition evidence with no overlap or gap" do
      cutoff = "2026-02-25T00:00:00Z"
      upsert = TopologyGraph.canonical_rebuild_upsert_query(cutoff)
      prune = TopologyGraph.prune_stale_mapper_evidence_links_query(cutoff)

      # Fresh evidence is projected and never pruned.
      assert upsert =~ "coalesce(r.last_observed_at, r.observed_at) >= '#{cutoff}'"
      assert prune =~ "coalesce(r.last_observed_at, r.observed_at) < '#{cutoff}'"

      # Timestamp-less evidence is pruned rather than projected forever.
      assert prune =~ "coalesce(r.last_observed_at, r.observed_at) IS NULL"

      # Must stay scoped to the timestamp: the upsert legitimately contains an
      # unrelated `cr.content_hash IS NULL OR ...` for the change-detection skip.
      refute upsert =~ "r.last_observed_at IS NULL OR"
    end

    test "legacy single-identifier attachment reconciliation converts ATTACHED_TO into OBSERVED_TO" do
      query = TopologyGraph.reconcile_legacy_single_identifier_attachment_links_query()

      assert query =~ "MATCH (ai:Interface)-[legacy:ATTACHED_TO]->(bi:Interface)"
      assert query =~ "MERGE (ai)-[observed:OBSERVED_TO]->(bi)"
      assert query =~ "toLower(coalesce(legacy.protocol, legacy.source, 'unknown')) = 'snmp-l2'"

      assert query =~
               "toLower(coalesce(legacy.confidence_reason, 'unknown')) = 'single_identifier_inference'"

      assert query =~ "DELETE legacy"
    end

    test "legacy canonical single-identifier attachment purge deletes polluted canonical edges" do
      query = TopologyGraph.purge_legacy_single_identifier_canonical_links_query()

      assert query =~ "MATCH ()-[r:CANONICAL_TOPOLOGY]->()"
      assert query =~ "toLower(coalesce(r.relation_type, 'unknown')) = 'attached_to'"
      assert query =~ "toLower(coalesce(r.protocol, 'unknown')) = 'snmp-l2'"

      assert query =~
               "toLower(coalesce(r.confidence_reason, 'unknown')) = 'single_identifier_inference'"

      assert query =~ "DELETE r"
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

    test "metric device IP extraction is IPv6-safe" do
      assert TopologyGraph.extract_metric_device_ip("2001:db8::10") == "2001:db8::10"
      assert TopologyGraph.extract_metric_device_ip("default:2001:db8::10") == "2001:db8::10"
      assert TopologyGraph.extract_metric_device_ip("default:192.0.2.10") == "192.0.2.10"

      refute TopologyGraph.extract_metric_device_ip("sr:device-1")
      refute TopologyGraph.extract_metric_device_ip("default:not-an-ip")
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
