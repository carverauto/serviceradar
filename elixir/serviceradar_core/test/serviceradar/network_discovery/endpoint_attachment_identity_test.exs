defmodule ServiceRadar.NetworkDiscovery.EndpointAttachmentIdentityTest do
  @moduledoc """
  Unit coverage (no database) for endpoint attachment identity promotion
  (fix-topology-evidence-pipeline-resilience, tasks 3.1/3.3):

    * flag OFF: the legacy suppression split is unchanged — FDB neighbors
      matching the 4-way suppression conjunction are suppressed, never minted;
    * flag ON: MAC-carrying FDB/UniFi-client neighbors — plus direct-physical
      LLDP/CDP and UniFi wired-client sightings
      (fix-cross-subnet-topology-attachment [G]) — become endpoint candidates
      (MAC+partition-keyed) instead of being suppressed, while MAC-less
      records keep the legacy IP-keyed rules (including suppression);
    * deterministic uid convergence: same MAC + partition always derives the
      same `sr:` uid regardless of observed IP (network-agnostic identity),
      and distinct MACs always derive distinct uids;
    * identity confidence tier derivation from the evidence class.
  """

  use ExUnit.Case, async: true

  alias ServiceRadar.Inventory.Identity.Ids
  alias ServiceRadar.Inventory.IdentityReconciler
  alias ServiceRadar.NetworkDiscovery.MapperResultsIngestor

  defp fdb_attachment_record(overrides \\ %{}) do
    %{
      "timestamp" => DateTime.truncate(DateTime.utc_now(), :microsecond),
      "protocol" => "SNMP-L2",
      "agent_id" => "agent-ea",
      "partition" => "default",
      "local_device_id" => "sr:ea-switch",
      "local_device_ip" => "192.0.2.10",
      "local_if_index" => 4,
      "neighbor_chassis_id" => "aa:bb:cc:dd:ee:01",
      "neighbor_mgmt_addr" => "192.0.2.77",
      "metadata" => %{
        "source" => "snmp-arp-fdb",
        "evidence" => "ipNetToMedia+dot1dTpFdb",
        "fdb_port_mapped" => "true",
        "evidence_class" => "inferred-segment",
        "relation_family" => "ATTACHED_TO",
        "confidence_tier" => "medium",
        "confidence_reason" => "single_identifier_inference"
      }
    }
    |> Map.merge(overrides)
    |> MapperResultsIngestor.normalize_topology()
  end

  defp lldp_endpoint_record(overrides \\ %{}) do
    %{
      "timestamp" => DateTime.truncate(DateTime.utc_now(), :microsecond),
      "protocol" => "LLDP",
      "agent_id" => "agent-ea",
      "partition" => "default",
      "local_device_id" => "sr:ea-switch",
      "local_device_ip" => "192.0.2.10",
      "local_if_index" => 7,
      "neighbor_chassis_id" => "aa:bb:cc:dd:ee:03",
      "neighbor_mgmt_addr" => "192.0.2.88",
      "metadata" => %{"source" => "lldp"}
    }
    |> Map.merge(overrides)
    |> MapperResultsIngestor.normalize_topology()
  end

  defp unifi_wired_client_record(overrides \\ %{}) do
    %{
      "timestamp" => DateTime.truncate(DateTime.utc_now(), :microsecond),
      "protocol" => "UniFi-API",
      "agent_id" => "agent-ea",
      "partition" => "default",
      "local_device_id" => "sr:ea-usw",
      "local_device_ip" => "192.0.2.30",
      "neighbor_chassis_id" => "aa:bb:cc:dd:ee:04",
      "neighbor_mgmt_addr" => "192.0.2.99",
      "metadata" => %{
        "source" => "unifi-api-wired-client",
        "relation_family" => "ATTACHED_TO",
        "confidence_tier" => "medium",
        "confidence_reason" => "controller_wired_client_switch_level"
      }
    }
    |> Map.merge(overrides)
    |> MapperResultsIngestor.normalize_topology()
  end

  defp unifi_wireless_client_record(overrides \\ %{}) do
    %{
      "timestamp" => DateTime.truncate(DateTime.utc_now(), :microsecond),
      "protocol" => "UniFi-API",
      "agent_id" => "agent-ea",
      "partition" => "default",
      "local_device_id" => "sr:ea-ap",
      "local_device_ip" => "192.0.2.20",
      "local_if_name" => "wireless",
      "neighbor_chassis_id" => "aa:bb:cc:dd:ee:02",
      "metadata" => %{
        "source" => "unifi-api-wireless-client",
        "evidence_class" => "endpoint-attachment",
        "relation_family" => "ATTACHED_TO",
        "confidence_tier" => "high",
        "confidence_reason" => "controller_client_association"
      }
    }
    |> Map.merge(overrides)
    |> MapperResultsIngestor.normalize_topology()
  end

  describe "flag off (default): suppression behavior is unchanged" do
    test "promotion flag defaults to disabled" do
      assert Application.get_env(
               :serviceradar_core,
               :topology_endpoint_identity_promotion_enabled,
               false
             ) == false
    end

    test "FDB attachment without a system name is still suppressed, never a candidate" do
      record = fdb_attachment_record()

      assert MapperResultsIngestor.suppress_topology_sighting_candidate?(record)

      assert %{endpoint: [], ip: [], suppressed: 1} =
               MapperResultsIngestor.partition_topology_sighting_candidates([record], false)
    end

    test "named FDB neighbor with a valid IP remains a legacy IP-keyed candidate" do
      record = fdb_attachment_record(%{"neighbor_system_name" => "host-77"})

      refute MapperResultsIngestor.suppress_topology_sighting_candidate?(record)

      assert %{endpoint: [], ip: [^record], suppressed: 0} =
               MapperResultsIngestor.partition_topology_sighting_candidates([record], false)
    end
  end

  describe "flag on: endpoint identity candidates" do
    test "suppressed FDB attachment becomes an endpoint candidate instead" do
      record = fdb_attachment_record()

      assert MapperResultsIngestor.endpoint_identity_candidate?(record)

      assert %{endpoint: [^record], ip: [], suppressed: 0} =
               MapperResultsIngestor.partition_topology_sighting_candidates([record], true)
    end

    test "UniFi wireless client without any IP is an endpoint candidate (MAC is enough)" do
      record = unifi_wireless_client_record()

      assert MapperResultsIngestor.endpoint_identity_candidate?(record)

      assert %{endpoint: [^record], ip: [], suppressed: 0} =
               MapperResultsIngestor.partition_topology_sighting_candidates([record], true)
    end

    test "FDB record without a usable MAC stays suppressed even when the flag is on" do
      record = fdb_attachment_record(%{"neighbor_chassis_id" => nil})

      refute MapperResultsIngestor.endpoint_identity_candidate?(record)

      assert %{endpoint: [], ip: [], suppressed: 1} =
               MapperResultsIngestor.partition_topology_sighting_candidates([record], true)
    end

    test "records with an already-resolved neighbor are not candidates" do
      record = fdb_attachment_record(%{"neighbor_device_id" => "sr:already-resolved"})

      refute MapperResultsIngestor.endpoint_identity_candidate?(record)
    end

    test "non-attachment sources never become endpoint candidates" do
      record =
        fdb_attachment_record(%{
          "metadata" => %{"source" => "unifi-api-uplink", "evidence_class" => "direct-physical"}
        })

      refute MapperResultsIngestor.endpoint_identity_candidate?(record)
    end

    test "LLDP endpoint sightings are endpoint candidates" do
      record = lldp_endpoint_record()

      assert MapperResultsIngestor.endpoint_identity_candidate?(record)

      assert %{endpoint: [^record], ip: [], suppressed: 0} =
               MapperResultsIngestor.partition_topology_sighting_candidates([record], true)
    end

    test "CDP endpoint sightings are endpoint candidates" do
      record = lldp_endpoint_record(%{"protocol" => "CDP", "metadata" => %{"source" => "cdp"}})

      assert MapperResultsIngestor.endpoint_identity_candidate?(record)

      assert %{endpoint: [^record], ip: [], suppressed: 0} =
               MapperResultsIngestor.partition_topology_sighting_candidates([record], true)
    end

    test "UniFi wired client sightings are endpoint candidates" do
      record = unifi_wired_client_record()

      assert MapperResultsIngestor.endpoint_identity_candidate?(record)

      assert %{endpoint: [^record], ip: [], suppressed: 0} =
               MapperResultsIngestor.partition_topology_sighting_candidates([record], true)
    end

    test "LLDP neighbors that already resolved are never candidates" do
      record = lldp_endpoint_record(%{"neighbor_device_id" => "sr:already-resolved"})

      refute MapperResultsIngestor.endpoint_identity_candidate?(record)
    end
  end

  describe "deterministic MAC+partition-keyed uid" do
    test "same MAC and partition converge on the same sr: uid regardless of IP" do
      mac = IdentityReconciler.normalize_mac("aa:bb:cc:dd:ee:01")

      uid_a =
        Ids.generate_deterministic_device_id(%{mac: mac, ip: "192.0.2.77", partition: "default"})

      uid_b =
        Ids.generate_deterministic_device_id(%{mac: mac, ip: "10.9.8.7", partition: "default"})

      uid_c = Ids.generate_deterministic_device_id(%{mac: mac, partition: "default"})

      assert String.starts_with?(uid_a, "sr:")
      assert uid_a == uid_b
      assert uid_a == uid_c
    end

    test "distinct MACs derive distinct uids (distinct hardware never converges)" do
      mac_a = IdentityReconciler.normalize_mac("aa:bb:cc:dd:ee:01")
      mac_b = IdentityReconciler.normalize_mac("aa:bb:cc:dd:ee:02")

      uid_a = Ids.generate_deterministic_device_id(%{mac: mac_a, partition: "default"})
      uid_b = Ids.generate_deterministic_device_id(%{mac: mac_b, partition: "default"})

      refute uid_a == uid_b
    end

    test "identity is partition-scoped" do
      mac = IdentityReconciler.normalize_mac("aa:bb:cc:dd:ee:01")

      uid_a = Ids.generate_deterministic_device_id(%{mac: mac, partition: "default"})
      uid_b = Ids.generate_deterministic_device_id(%{mac: mac, partition: "site-b"})

      refute uid_a == uid_b
    end
  end

  describe "identity confidence tier from evidence class" do
    test "maps evidence classes onto identity confidence tiers" do
      assert MapperResultsIngestor.endpoint_identity_confidence_tier("endpoint-attachment") ==
               "high"

      assert MapperResultsIngestor.endpoint_identity_confidence_tier("direct-physical") == "high"

      assert MapperResultsIngestor.endpoint_identity_confidence_tier("inferred-segment") ==
               "medium"

      assert MapperResultsIngestor.endpoint_identity_confidence_tier("hosted-virtual") ==
               "medium"

      assert MapperResultsIngestor.endpoint_identity_confidence_tier("observed-only") == "low"
      assert MapperResultsIngestor.endpoint_identity_confidence_tier("mystery") == "low"
      assert MapperResultsIngestor.endpoint_identity_confidence_tier(nil) == "low"
    end

    test "endpoint candidate metadata carries the MAC and derived identity tier" do
      record = fdb_attachment_record()
      mac = IdentityReconciler.normalize_mac("aa:bb:cc:dd:ee:01")

      metadata = MapperResultsIngestor.endpoint_topology_candidate_metadata(record, mac)

      assert metadata["topology_last_seen_neighbor_mac"] == mac
      assert metadata["identity_confidence_tier"] == "medium"
      assert metadata["topology_last_seen_protocol"] == "snmp-l2"
    end

    test "LLDP/CDP-sourced promotions are capped at medium identity confidence" do
      assert MapperResultsIngestor.endpoint_identity_confidence_tier("direct-physical", "lldp") ==
               "medium"

      assert MapperResultsIngestor.endpoint_identity_confidence_tier("direct-physical", "cdp") ==
               "medium"

      assert MapperResultsIngestor.endpoint_identity_confidence_tier("observed-only", "lldp") ==
               "low"

      assert MapperResultsIngestor.endpoint_identity_confidence_tier(
               "direct-physical",
               "snmp-arp-fdb"
             ) == "high"

      assert MapperResultsIngestor.endpoint_identity_confidence_tier(
               "endpoint-attachment",
               "unifi-api-wired-client"
             ) == "high"
    end

    test "LLDP endpoint candidate metadata carries the medium identity tier" do
      record = lldp_endpoint_record()
      mac = IdentityReconciler.normalize_mac("aa:bb:cc:dd:ee:03")

      metadata = MapperResultsIngestor.endpoint_topology_candidate_metadata(record, mac)

      assert metadata["topology_last_seen_neighbor_mac"] == mac
      assert metadata["identity_confidence_tier"] == "medium"
      assert metadata["topology_last_seen_protocol"] == "lldp"
    end
  end

  describe "endpoint IP/MAC bind evidence" do
    test "same-subnet ARP+FDB may bind a sighting MAC onto an IP-only device" do
      assert MapperResultsIngestor.endpoint_ip_mac_bind_allowed?(%{
               "source" => "snmp-arp-fdb",
               "confidence_reason" => "arp_fdb_port_mapping"
             })

      assert MapperResultsIngestor.endpoint_ip_mac_bind_allowed?(%{
               "source" => "lldp"
             })
    end

    test "cross-subnet and observed-join FDB must not bind a sighting MAC onto an IP-only device" do
      refute MapperResultsIngestor.endpoint_ip_mac_bind_allowed?(%{
               "source" => "snmp-arp-fdb",
               "confidence_reason" => "cross_subnet_arp_fdb_port_mapping"
             })

      refute MapperResultsIngestor.endpoint_ip_mac_bind_allowed?(%{
               "source" => "snmp-arp-fdb",
               "confidence_reason" => "cross_device_arp_fdb_join"
             })

      refute MapperResultsIngestor.endpoint_ip_mac_bind_allowed?(%{
               "topology_last_seen_confidence_reason" => "cross_subnet_arp_fdb_port_mapping"
             })
    end
  end
end
