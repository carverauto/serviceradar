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

      assert {:ok, %{mode: :backbone, relation: "CONNECTS_TO"}} =
               TopologyGraph.classify_projection(normalized)
    end

    test "SNMP ARP/FDB single-identifier evidence never becomes backbone" do
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

      assert {:ok, %{mode: :auxiliary, relation: "ATTACHED_TO"}} =
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

      assert {:ok, %{mode: :auxiliary, relation: "INFERRED_TO"}} =
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

      assert {:ok, %{mode: :skip, relation: nil}} =
               TopologyGraph.classify_projection(normalized)
    end
  end
end
