defmodule ServiceRadar.NetworkDiscovery.MapperResultsIngestorTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias ServiceRadar.NetworkDiscovery.MapperResultsIngestor

  describe "normalize_interface/1 with available_metrics" do
    test "normalizes available_metrics from string-keyed map" do
      update = %{
        "device_id" => "device-001",
        "device_ip" => "192.168.1.1",
        "if_index" => 1,
        "if_name" => "eth0",
        "available_metrics" => [
          %{
            "name" => "ifInOctets",
            "oid" => ".1.3.6.1.2.1.2.2.1.10",
            "data_type" => "counter",
            "supports_64bit" => true,
            "oid_64bit" => ".1.3.6.1.2.1.31.1.1.1.6",
            "category" => "traffic",
            "unit" => "bytes"
          },
          %{
            "name" => "ifOutOctets",
            "oid" => ".1.3.6.1.2.1.2.2.1.16",
            "data_type" => "counter",
            "supports_64bit" => true,
            "oid_64bit" => ".1.3.6.1.2.1.31.1.1.1.10",
            "category" => "traffic",
            "unit" => "bytes"
          }
        ]
      }

      result = MapperResultsIngestor.normalize_interface(update)

      assert result != nil
      assert result.available_metrics != nil
      assert length(result.available_metrics) == 2

      [first, second] = result.available_metrics

      assert first["name"] == "ifInOctets"
      assert first["oid"] == ".1.3.6.1.2.1.2.2.1.10"
      assert first["data_type"] == "counter"
      assert first["supports_64bit"] == true
      assert first["oid_64bit"] == ".1.3.6.1.2.1.31.1.1.1.6"
      assert first["category"] == "traffic"
      assert first["unit"] == "bytes"

      assert second["name"] == "ifOutOctets"
      assert second["category"] == "traffic"
    end

    test "normalizes available_metrics from atom-keyed map" do
      update = %{
        device_id: "device-001",
        device_ip: "192.168.1.1",
        if_index: 1,
        if_name: "eth0",
        available_metrics: [
          %{
            name: "ifInErrors",
            oid: ".1.3.6.1.2.1.2.2.1.14",
            data_type: "counter",
            supports_64bit: false,
            oid_64bit: "",
            category: "errors",
            unit: "errors"
          }
        ]
      }

      result = MapperResultsIngestor.normalize_interface(update)

      assert result != nil
      assert result.available_metrics != nil
      assert length(result.available_metrics) == 1

      [metric] = result.available_metrics

      assert metric["name"] == "ifInErrors"
      assert metric["oid"] == ".1.3.6.1.2.1.2.2.1.14"
      assert metric["data_type"] == "counter"
      assert metric["supports_64bit"] == false
      assert metric["category"] == "errors"
      assert metric["unit"] == "errors"
    end

    test "returns nil available_metrics for empty list" do
      update = %{
        "device_id" => "device-001",
        "device_ip" => "192.168.1.1",
        "if_index" => 1,
        "if_name" => "eth0",
        "available_metrics" => []
      }

      result = MapperResultsIngestor.normalize_interface(update)

      assert result != nil
      assert result.available_metrics == nil
    end

    test "returns nil available_metrics for missing field" do
      update = %{
        "device_id" => "device-001",
        "device_ip" => "192.168.1.1",
        "if_index" => 1,
        "if_name" => "eth0"
      }

      result = MapperResultsIngestor.normalize_interface(update)

      assert result != nil
      assert result.available_metrics == nil
    end

    test "returns nil available_metrics for invalid value (not a list)" do
      update = %{
        "device_id" => "device-001",
        "device_ip" => "192.168.1.1",
        "if_index" => 1,
        "if_name" => "eth0",
        "available_metrics" => "invalid"
      }

      result = MapperResultsIngestor.normalize_interface(update)

      assert result != nil
      assert result.available_metrics == nil
    end

    test "handles metrics with all categories" do
      update = %{
        "device_id" => "device-001",
        "device_ip" => "192.168.1.1",
        "if_index" => 1,
        "if_name" => "eth0",
        "available_metrics" => [
          %{"name" => "ifInOctets", "category" => "traffic", "unit" => "bytes"},
          %{"name" => "ifInErrors", "category" => "errors", "unit" => "errors"},
          %{"name" => "ifInUcastPkts", "category" => "packets", "unit" => "packets"},
          %{"name" => "temperature", "category" => "environmental", "unit" => "celsius"},
          %{"name" => "powerStatus", "category" => "status", "unit" => "boolean"}
        ]
      }

      result = MapperResultsIngestor.normalize_interface(update)

      assert result != nil
      assert result.available_metrics != nil
      assert length(result.available_metrics) == 5

      categories = Enum.map(result.available_metrics, & &1["category"])
      assert "traffic" in categories
      assert "errors" in categories
      assert "packets" in categories
      assert "environmental" in categories
      assert "status" in categories
    end

    test "handles supports_64bit as string" do
      update = %{
        "device_id" => "device-001",
        "device_ip" => "192.168.1.1",
        "if_index" => 1,
        "if_name" => "eth0",
        "available_metrics" => [
          %{"name" => "ifInOctets", "supports_64bit" => "true"},
          %{"name" => "ifInErrors", "supports_64bit" => "false"}
        ]
      }

      result = MapperResultsIngestor.normalize_interface(update)

      assert result != nil
      assert result.available_metrics != nil
      [first, second] = result.available_metrics

      assert first["supports_64bit"] == true
      assert second["supports_64bit"] == false
    end

    test "handles mixed key formats in metric maps" do
      update = %{
        "device_id" => "device-001",
        "device_ip" => "192.168.1.1",
        "if_index" => 1,
        "if_name" => "eth0",
        "available_metrics" => [
          %{
            "name" => "ifInOctets",
            :oid => ".1.3.6.1.2.1.2.2.1.10",
            "DataType" => "counter",
            :category => "traffic"
          }
        ]
      }

      result = MapperResultsIngestor.normalize_interface(update)

      assert result != nil
      assert result.available_metrics != nil
      [metric] = result.available_metrics

      # The normalize_metric function should handle the various key formats
      assert metric["name"] == "ifInOctets"
      assert metric["oid"] == ".1.3.6.1.2.1.2.2.1.10"
      assert metric["category"] == "traffic"
    end

    test "preserves all interface fields alongside available_metrics" do
      update = %{
        "device_id" => "device-001",
        "device_ip" => "192.168.1.1",
        "if_index" => 1,
        "if_name" => "eth0",
        "if_descr" => "Ethernet Interface 0",
        "if_type" => 6,
        "if_speed" => 1_000_000_000,
        "if_admin_status" => 1,
        "if_oper_status" => 1,
        "available_metrics" => [
          %{
            "name" => "ifInOctets",
            "oid" => ".1.3.6.1.2.1.2.2.1.10",
            "data_type" => "counter",
            "supports_64bit" => true,
            "oid_64bit" => ".1.3.6.1.2.1.31.1.1.1.6",
            "category" => "traffic",
            "unit" => "bytes"
          }
        ]
      }

      result = MapperResultsIngestor.normalize_interface(update)

      assert result != nil
      assert result.device_id == "device-001"
      assert result.device_ip == "192.168.1.1"
      assert result.if_index == 1
      assert result.if_name == "eth0"
      assert result.if_descr == "Ethernet Interface 0"
      assert result.if_type == 6
      assert result.if_speed == 1_000_000_000
      assert result.if_admin_status == 1
      assert result.if_oper_status == 1
      assert result.available_metrics != nil
      assert length(result.available_metrics) == 1
    end
  end

  describe "normalize_topology/1 confidence scoring" do
    test "assigns high confidence to LLDP links" do
      result =
        MapperResultsIngestor.normalize_topology(%{
          "protocol" => "LLDP",
          "local_device_ip" => "192.168.1.1",
          "neighbor_port_id" => "Gi1/0/1",
          "neighbor_mgmt_addr" => "192.168.1.2",
          "neighbor_system_name" => "switch-01",
          "metadata" => %{}
        })

      assert result.metadata["confidence_tier"] == "high"
      assert result.metadata["confidence_score"] == 95
      assert result.metadata["confidence_reason"] == "direct_lldp_neighbor"
    end

    test "assigns medium confidence to unifi-api bridge/uplink links" do
      result =
        MapperResultsIngestor.normalize_topology(%{
          "protocol" => "UniFi-API",
          "local_device_ip" => "192.168.1.130",
          "neighbor_port_id" => "eth0",
          "neighbor_chassis_id" => "aa:bb:cc:dd:ee:ff",
          "neighbor_mgmt_addr" => "192.168.1.131",
          "metadata" => %{"source" => "unifi-api"}
        })

      assert result.metadata["confidence_tier"] == "medium"
      assert result.metadata["confidence_score"] == 78
      assert result.metadata["confidence_reason"] == "bridge_uplink_with_neighbor_ip"
    end

    test "assigns low confidence when evidence is insufficient" do
      result =
        MapperResultsIngestor.normalize_topology(%{
          "protocol" => "unknown",
          "local_device_ip" => "192.168.1.130",
          "metadata" => %{}
        })

      assert result.metadata["confidence_tier"] == "low"
      assert result.metadata["confidence_score"] == 20
      assert result.metadata["confidence_reason"] == "insufficient_neighbor_evidence"
    end

    test "hydrates topology neighbor fields from neighbor_identity payload" do
      result =
        MapperResultsIngestor.normalize_topology(%{
          "protocol" => "LLDP",
          "local_device_ip" => "192.168.1.195",
          "local_device_id" => "sr:uswpro24-a",
          "neighbor_identity" => %{
            "management_ip" => "192.168.1.87",
            "device_id" => "sr:usw-aggregation",
            "chassis_id" => "aa:bb:cc:dd:ee:ff",
            "port_id" => "Gi1/0/48",
            "port_descr" => "uplink",
            "system_name" => "USWAggregation"
          },
          "metadata" => %{}
        })

      assert result.neighbor_mgmt_addr == "192.168.1.87"
      assert result.neighbor_device_id == "sr:usw-aggregation"
      assert result.neighbor_chassis_id == "aa:bb:cc:dd:ee:ff"
      assert result.neighbor_port_id == "Gi1/0/48"
      assert result.neighbor_port_descr == "uplink"
      assert result.neighbor_system_name == "USWAggregation"
      assert result.metadata["neighbor_identity"]["management_ip"] == "192.168.1.87"
    end
  end

  describe "resolve_topology_records/2" do
    test "resolves local and neighbor by IP first and keeps unresolved neighbor" do
      records = [
        %{
          local_device_id: "default:192.168.1.1",
          local_device_ip: "192.168.1.1",
          neighbor_device_id: nil,
          neighbor_mgmt_addr: "192.168.1.87",
          neighbor_system_name: nil,
          neighbor_chassis_id: nil
        },
        %{
          local_device_id: "default:192.168.1.1",
          local_device_ip: "192.168.1.1",
          neighbor_device_id: nil,
          neighbor_mgmt_addr: nil,
          neighbor_system_name: "external-host",
          neighbor_chassis_id: nil
        }
      ]

      index = %{
        uid_to_uid: %{"sr:farm01" => "sr:farm01"},
        ip_to_uid: %{
          "192.168.1.1" => "sr:farm01",
          "192.168.1.87" => "sr:uswagg"
        },
        name_to_uid: %{},
        mac_to_uid: %{}
      }

      [resolved, unresolved_neighbor] =
        MapperResultsIngestor.resolve_topology_records(records, index)

      assert resolved.local_device_id == "sr:farm01"
      assert resolved.neighbor_device_id == "sr:uswagg"
      assert unresolved_neighbor.local_device_id == "sr:farm01"
      assert unresolved_neighbor.neighbor_device_id == nil
    end

    test "resolves neighbor from system name and chassis id when mgmt ip is missing" do
      records = [
        %{
          local_device_id: "sr:farm01",
          local_device_ip: "192.168.1.1",
          neighbor_device_id: nil,
          neighbor_mgmt_addr: nil,
          neighbor_system_name: "USWAggregation.local",
          neighbor_chassis_id: nil
        },
        %{
          local_device_id: "sr:farm01",
          local_device_ip: "192.168.1.1",
          neighbor_device_id: nil,
          neighbor_mgmt_addr: nil,
          neighbor_system_name: nil,
          neighbor_chassis_id: "AA:BB:CC:DD:EE:FF"
        }
      ]

      index = %{
        uid_to_uid: %{"sr:farm01" => "sr:farm01", "sr:uswagg" => "sr:uswagg"},
        ip_to_uid: %{"192.168.1.1" => "sr:farm01"},
        name_to_uid: %{"uswaggregation" => "sr:uswagg"},
        mac_to_uid: %{"AABBCCDDEEFF" => "sr:uswagg"}
      }

      [by_name, by_mac] = MapperResultsIngestor.resolve_topology_records(records, index)

      assert by_name.neighbor_device_id == "sr:uswagg"
      assert by_mac.neighbor_device_id == "sr:uswagg"
    end

    test "preserves records when local endpoint cannot be canonically resolved" do
      records = [
        %{
          local_device_id: "default:10.10.10.10",
          local_device_ip: "10.10.10.10",
          neighbor_device_id: nil,
          neighbor_mgmt_addr: "192.168.1.87",
          neighbor_system_name: "USWAggregation",
          neighbor_chassis_id: nil
        }
      ]

      index = %{
        uid_to_uid: %{},
        ip_to_uid: %{"192.168.1.87" => "sr:uswagg"},
        name_to_uid: %{"uswaggregation" => "sr:uswagg"},
        mac_to_uid: %{}
      }

      [resolved] = MapperResultsIngestor.resolve_topology_records(records, index)
      assert resolved.local_device_id == "default:10.10.10.10"
      assert resolved.neighbor_device_id == "sr:uswagg"
    end
  end

  describe "topology_candidate_metadata/1" do
    test "builds freshness and confidence metadata for topology-only endpoint sightings" do
      ts = ~U[2026-02-15 12:30:00Z]

      metadata =
        MapperResultsIngestor.topology_candidate_metadata(%{
          timestamp: ts,
          neighbor_mgmt_addr: "192.168.10.96",
          local_device_id: "sr:aruba-10-154",
          protocol: "LLDP",
          metadata: %{
            "confidence_tier" => "medium",
            "confidence_score" => 66,
            "confidence_reason" => "port_neighbor_inference"
          }
        })

      assert metadata["topology_last_seen_at"] == "2026-02-15T12:30:00Z"
      assert metadata["topology_last_seen_neighbor_ip"] == "192.168.10.96"
      assert metadata["topology_last_seen_from_device_id"] == "sr:aruba-10-154"
      assert metadata["topology_last_seen_protocol"] == "lldp"
      assert metadata["topology_last_seen_confidence_tier"] == "medium"
      assert metadata["topology_last_seen_confidence_score"] == "66"
      assert metadata["topology_last_seen_confidence_reason"] == "port_neighbor_inference"
    end
  end
end
