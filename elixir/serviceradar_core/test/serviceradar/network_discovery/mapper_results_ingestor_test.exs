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

    test "strips unifi controller metadata for non-unifi interface rows" do
      update = %{
        "device_id" => "device-001",
        "device_ip" => "192.168.1.1",
        "if_index" => 1,
        "if_name" => "1",
        "source" => "snmp",
        "metadata" => %{
          "source" => "snmp",
          "discovery_id" => "abc",
          "unifi_api_urls" => "https://192.168.10.1/proxy/network/integration/v1",
          "unifi_api_names" => "tonka01",
          "controller_name" => "tonka01"
        }
      }

      result = MapperResultsIngestor.normalize_interface(update)

      assert result != nil
      assert result.metadata["source"] == "snmp"
      assert result.metadata["discovery_id"] == "abc"
      refute Map.has_key?(result.metadata, "unifi_api_urls")
      refute Map.has_key?(result.metadata, "unifi_api_names")
      refute Map.has_key?(result.metadata, "controller_name")
    end

    test "keeps unifi metadata for unifi interface rows" do
      update = %{
        "device_id" => "device-001",
        "device_ip" => "192.168.1.1",
        "if_index" => 1,
        "if_name" => "eth0",
        "source" => "unifi-api",
        "metadata" => %{
          "source" => "unifi-api",
          "unifi_api_urls" => "https://192.168.2.1/proxy/network/integration/v1"
        }
      }

      result = MapperResultsIngestor.normalize_interface(update)

      assert result != nil

      assert result.metadata["unifi_api_urls"] ==
               "https://192.168.2.1/proxy/network/integration/v1"
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

    test "hydrates topology from observation v2 envelope and preserves source endpoint uids" do
      result =
        MapperResultsIngestor.normalize_topology(%{
          "metadata" => %{
            "source" => "snmp-arp-fdb",
            "observation_v2_json" =>
              Jason.encode!(%{
                "contract_version" => "mapper.topology_observation.v2",
                "source_protocol" => "snmp-l2",
                "source_adapter" => "snmp.v1",
                "evidence_class" => "inferred",
                "confidence_tier" => "medium",
                "source_endpoint" => %{
                  "uid" => "mac-f492bf75c721",
                  "device_id" => "mac-f492bf75c721",
                  "ip" => "152.117.116.178",
                  "if_name" => "eth0"
                },
                "target_endpoint" => %{
                  "uid" => "chassis-0cea1432d277",
                  "device_id" => "sr:tonka01",
                  "ip" => "192.168.10.1",
                  "mac" => "0c:ea:14:32:d2:77",
                  "port_id" => "eth4"
                }
              })
          }
        })

      assert result.protocol == "snmp-l2"
      assert result.local_device_id == "mac-f492bf75c721"
      assert result.local_if_name == "eth0"
      assert result.neighbor_device_id == "sr:tonka01"
      assert result.neighbor_mgmt_addr == "192.168.10.1"
      assert result.neighbor_port_id == "eth4"
      assert result.metadata["observation_contract_version"] == "mapper.topology_observation.v2"
      assert result.metadata["observation_source_adapter"] == "snmp.v1"
      assert result.metadata["source_local_uid"] == "mac-f492bf75c721"
      assert result.metadata["source_target_uid"] == "chassis-0cea1432d277"
      assert result.metadata["confidence_tier"] == "medium"
      assert result.metadata["evidence_class"] == "inferred"
    end
  end

  describe "prune_unattributed_unifi_links/1" do
    test "drops unattributed UniFi links when attributed SNMP-like evidence exists for same pair" do
      left = "sr:left-1"
      right = "sr:right-1"

      records = [
        %{
          protocol: "UniFi-API",
          local_device_id: left,
          local_device_ip: "192.168.1.10",
          local_if_index: 0,
          local_if_name: nil,
          neighbor_device_id: right,
          neighbor_mgmt_addr: "192.168.1.11"
        },
        %{
          protocol: "LLDP",
          local_device_id: left,
          local_device_ip: "192.168.1.10",
          local_if_index: 7,
          local_if_name: "eth7",
          neighbor_device_id: right,
          neighbor_mgmt_addr: "192.168.1.11"
        }
      ]

      pruned = MapperResultsIngestor.prune_unattributed_unifi_links(records)
      assert length(pruned) == 1
      assert hd(pruned).protocol == "LLDP"
    end

    test "keeps unattributed UniFi links when no attributed evidence exists for pair" do
      records = [
        %{
          protocol: "UniFi-API",
          local_device_id: "sr:left-2",
          local_device_ip: "192.168.1.20",
          local_if_index: 0,
          local_if_name: nil,
          neighbor_device_id: "sr:right-2",
          neighbor_mgmt_addr: "192.168.1.21"
        }
      ]

      assert MapperResultsIngestor.prune_unattributed_unifi_links(records) == records
    end
  end

  describe "infer_reverse_interface_hints/1" do
    test "infers local_if_name from reverse LLDP neighbor port id" do
      records = [
        %{
          protocol: "LLDP",
          local_device_id: "sr:uswpro24-a",
          neighbor_device_id: "sr:uswagg",
          local_if_index: 25,
          local_if_name: nil,
          neighbor_port_id: "50:6f:72:74:20:31",
          neighbor_port_descr: "SFP_ 1",
          metadata: %{"confidence_tier" => "high"}
        },
        %{
          protocol: "UniFi-API",
          local_device_id: "sr:uswagg",
          neighbor_device_id: "sr:uswpro24-a",
          local_if_index: 0,
          local_if_name: nil,
          neighbor_port_id: nil,
          neighbor_port_descr: nil,
          metadata: %{}
        }
      ]

      [_, reverse] = MapperResultsIngestor.infer_reverse_interface_hints(records)
      assert reverse.local_if_name == "port 1"
      assert reverse.metadata["local_if_name_inferred"] == "port 1"
    end

    test "does not override existing local interface attribution" do
      records = [
        %{
          protocol: "LLDP",
          local_device_id: "sr:a",
          neighbor_device_id: "sr:b",
          local_if_index: 12,
          local_if_name: nil,
          neighbor_port_id: "50:6f:72:74:20:32",
          neighbor_port_descr: "Port 2",
          metadata: %{"confidence_tier" => "high"}
        },
        %{
          protocol: "UniFi-API",
          local_device_id: "sr:b",
          neighbor_device_id: "sr:a",
          local_if_index: 8,
          local_if_name: "Port 8",
          neighbor_port_id: nil,
          neighbor_port_descr: nil,
          metadata: %{}
        }
      ]

      [_, reverse] = MapperResultsIngestor.infer_reverse_interface_hints(records)
      assert reverse.local_if_index == 8
      assert reverse.local_if_name == "Port 8"
      refute Map.has_key?(reverse.metadata, "local_if_name_inferred")
    end
  end

  describe "suppress_topology_sighting_candidate?/1" do
    test "suppresses low-confidence public SNMP ARP/FDB sightings without neighbor name" do
      record = %{
        protocol: "SNMP-L2",
        neighbor_mgmt_addr: "204.209.51.58",
        neighbor_system_name: nil,
        metadata: %{
          "source" => "snmp-arp-fdb",
          "confidence_reason" => "single_identifier_inference"
        }
      }

      assert MapperResultsIngestor.suppress_topology_sighting_candidate?(record)
    end

    test "does not suppress private-address SNMP ARP/FDB sightings" do
      record = %{
        protocol: "SNMP-L2",
        neighbor_mgmt_addr: "192.168.1.87",
        neighbor_system_name: nil,
        metadata: %{
          "source" => "snmp-arp-fdb",
          "confidence_reason" => "single_identifier_inference"
        }
      }

      refute MapperResultsIngestor.suppress_topology_sighting_candidate?(record)
    end

    test "does not suppress when neighbor system name is present" do
      record = %{
        protocol: "SNMP-L2",
        neighbor_mgmt_addr: "204.209.51.58",
        neighbor_system_name: "wan-uplink",
        metadata: %{
          "source" => "snmp-arp-fdb",
          "confidence_reason" => "single_identifier_inference"
        }
      }

      refute MapperResultsIngestor.suppress_topology_sighting_candidate?(record)
    end
  end

  describe "resolve_topology_records/2" do
    test "sanitize_topology_records/1 strips non-canonical endpoint ids before resolution" do
      records = [
        %{
          local_device_id: "nil",
          local_device_ip: "192.168.10.1",
          neighbor_device_id: "default:192.168.10.154",
          neighbor_mgmt_addr: "192.168.10.154",
          metadata: %{}
        }
      ]

      [sanitized] = MapperResultsIngestor.sanitize_topology_records(records)

      assert sanitized.local_device_id == nil
      assert sanitized.neighbor_device_id == nil
      assert sanitized.metadata["source_local_uid"] == nil
      assert sanitized.metadata["source_target_uid"] == "default:192.168.10.154"
    end

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
      assert resolved.metadata["source_local_uid"] == "default:192.168.1.1"
      assert resolved.metadata["source_target_uid"] == nil
      assert unresolved_neighbor.local_device_id == "sr:farm01"
      assert unresolved_neighbor.neighbor_device_id == nil
      assert unresolved_neighbor.metadata["source_local_uid"] == "default:192.168.1.1"
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
      assert is_binary(resolved.local_device_id)
      assert String.starts_with?(resolved.local_device_id, "sr:")
      assert resolved.neighbor_device_id == "sr:uswagg"
      assert resolved.metadata["source_local_uid"] == "default:10.10.10.10"
    end

    test "treats default-prefixed neighbor ids as unresolved when canonical device cannot be found" do
      records = [
        %{
          local_device_id: "sr:tonka01",
          local_device_ip: "192.168.10.1",
          neighbor_device_id: "default:192.168.10.96",
          neighbor_mgmt_addr: "192.168.10.96",
          neighbor_system_name: nil,
          neighbor_chassis_id: nil,
          partition: "default"
        }
      ]

      index = %{
        uid_to_uid: %{"sr:tonka01" => "sr:tonka01"},
        ip_to_uid: %{"192.168.10.1" => "sr:tonka01"},
        name_to_uid: %{},
        mac_to_uid: %{}
      }

      [resolved] = MapperResultsIngestor.resolve_topology_records(records, index)
      assert resolved.local_device_id == "sr:tonka01"
      assert resolved.neighbor_device_id == nil
      assert resolved.metadata["source_target_uid"] == "default:192.168.10.96"
    end

    test "treats sentinel neighbor ids as unresolved" do
      records = [
        %{
          local_device_id: "sr:tonka01",
          local_device_ip: "192.168.10.1",
          neighbor_device_id: "nil",
          neighbor_mgmt_addr: nil,
          neighbor_system_name: nil,
          neighbor_chassis_id: nil,
          partition: "default"
        }
      ]

      index = %{
        uid_to_uid: %{"sr:tonka01" => "sr:tonka01"},
        ip_to_uid: %{"192.168.10.1" => "sr:tonka01"},
        name_to_uid: %{},
        mac_to_uid: %{}
      }

      [resolved] = MapperResultsIngestor.resolve_topology_records(records, index)
      assert resolved.local_device_id == "sr:tonka01"
      assert resolved.neighbor_device_id == nil
      assert resolved.metadata["source_target_uid"] == nil
    end

    test "ignores non-canonical index mappings and falls back to canonical id generation" do
      records = [
        %{
          local_device_id: "nil",
          local_device_ip: "192.168.10.1",
          neighbor_device_id: nil,
          neighbor_mgmt_addr: "192.168.10.154",
          neighbor_system_name: nil,
          neighbor_chassis_id: nil,
          partition: "default"
        }
      ]

      index = %{
        uid_to_uid: %{"nil" => "nil"},
        ip_to_uid: %{"192.168.10.1" => "nil", "192.168.10.154" => "nil"},
        name_to_uid: %{},
        mac_to_uid: %{}
      }

      [resolved] = MapperResultsIngestor.resolve_topology_records(records, index)
      assert is_binary(resolved.local_device_id)
      assert String.starts_with?(resolved.local_device_id, "sr:")
      assert resolved.local_device_id != "nil"
      assert resolved.neighbor_device_id == nil
      assert resolved.metadata["source_local_uid"] == nil
    end

    test "falls through poisoned uid mapping and still resolves by ip" do
      records = [
        %{
          local_device_id: "default:192.168.10.1",
          local_device_ip: "192.168.10.1",
          neighbor_device_id: nil,
          neighbor_mgmt_addr: "192.168.10.154",
          neighbor_system_name: nil,
          neighbor_chassis_id: nil,
          partition: "default"
        }
      ]

      index = %{
        uid_to_uid: %{"default:192.168.10.1" => "nil"},
        ip_to_uid: %{
          "192.168.10.1" => "sr:tonka01",
          "192.168.10.154" => "sr:aruba-10-154"
        },
        name_to_uid: %{},
        mac_to_uid: %{}
      }

      [resolved] = MapperResultsIngestor.resolve_topology_records(records, index)
      assert resolved.local_device_id == "sr:tonka01"
      assert resolved.neighbor_device_id == "sr:aruba-10-154"
      assert resolved.metadata["source_local_uid"] == "default:192.168.10.1"
    end

    test "preserves canonical sr neighbor ids even when they are not indexed" do
      records = [
        %{
          local_device_id: "sr:tonka01",
          local_device_ip: "192.168.10.1",
          neighbor_device_id: "sr:endpoint-10-96",
          neighbor_mgmt_addr: "192.168.10.96",
          neighbor_system_name: nil,
          neighbor_chassis_id: nil,
          partition: "default"
        }
      ]

      index = %{
        uid_to_uid: %{"sr:tonka01" => "sr:tonka01"},
        ip_to_uid: %{"192.168.10.1" => "sr:tonka01"},
        name_to_uid: %{},
        mac_to_uid: %{}
      }

      [resolved] = MapperResultsIngestor.resolve_topology_records(records, index)
      assert resolved.local_device_id == "sr:tonka01"
      assert resolved.neighbor_device_id == "sr:endpoint-10-96"
    end

    test "preserves explicit canonical device ids ahead of conflicting ip matches" do
      records = [
        %{
          local_device_id: "sr:tonka01",
          local_device_ip: "192.168.10.1",
          neighbor_device_id: "sr:aruba-10-154",
          neighbor_mgmt_addr: "192.168.10.154",
          neighbor_system_name: "aruba-24g-02",
          neighbor_chassis_id: nil,
          partition: "default"
        }
      ]

      index = %{
        uid_to_uid: %{},
        ip_to_uid: %{
          "192.168.10.1" => "sr:7fcc84b5-fb2f-4624-9451-23b00bbbe9ea",
          "192.168.10.154" => "sr:aruba-10-154"
        },
        name_to_uid: %{"aruba-24g-02" => "sr:aruba-10-154"},
        mac_to_uid: %{}
      }

      [resolved] = MapperResultsIngestor.resolve_topology_records(records, index)
      assert resolved.local_device_id == "sr:tonka01"
      assert resolved.neighbor_device_id == "sr:aruba-10-154"
    end

    test "reconciles previously unresolved endpoints after canonical identity becomes available" do
      records = [
        %{
          local_device_id: "sr:tonka01",
          local_device_ip: "192.168.10.1",
          neighbor_device_id: "default:192.168.10.154",
          neighbor_mgmt_addr: "192.168.10.154",
          neighbor_system_name: "aruba-24g-02",
          neighbor_chassis_id: nil,
          partition: "default"
        }
      ]

      unresolved_index = %{
        uid_to_uid: %{"sr:tonka01" => "sr:tonka01"},
        ip_to_uid: %{"192.168.10.1" => "sr:tonka01"},
        name_to_uid: %{},
        mac_to_uid: %{}
      }

      [unresolved] = MapperResultsIngestor.resolve_topology_records(records, unresolved_index)
      assert unresolved.local_device_id == "sr:tonka01"
      assert unresolved.neighbor_device_id == nil
      assert unresolved.metadata["source_target_uid"] == "default:192.168.10.154"

      reconciled_index = %{
        uid_to_uid: %{"sr:tonka01" => "sr:tonka01", "sr:aruba-10-154" => "sr:aruba-10-154"},
        ip_to_uid: %{
          "192.168.10.1" => "sr:tonka01",
          "192.168.10.154" => "sr:aruba-10-154"
        },
        name_to_uid: %{"aruba-24g-02" => "sr:aruba-10-154"},
        mac_to_uid: %{}
      }

      [reconciled] = MapperResultsIngestor.resolve_topology_records(records, reconciled_index)
      assert reconciled.local_device_id == "sr:tonka01"
      assert reconciled.neighbor_device_id == "sr:aruba-10-154"
      assert reconciled.metadata["source_target_uid"] == "default:192.168.10.154"
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

  describe "infer_wireguard_tunnel_links/3" do
    test "infers farm01 to tonka01 wireguard edge from matching tunnel interface name" do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      records = [
        %{
          timestamp: now,
          agent_id: "agent-1",
          gateway_id: "gw-1",
          partition: "default",
          protocol: "SNMP-L2",
          local_device_id: "sr:farm01",
          local_device_ip: "192.168.2.1",
          neighbor_device_id: "sr:uswagg",
          neighbor_mgmt_addr: "192.168.1.87"
        }
      ]

      interfaces = [
        %{
          device_id: "sr:farm01",
          timestamp: now,
          if_name: "wgsts1000",
          if_descr: "wgsts1000",
          ip_addresses: ["192.168.0.0"]
        },
        %{
          device_id: "sr:tonka01",
          timestamp: now,
          if_name: "wgsts1000",
          if_descr: "wgsts1000",
          ip_addresses: ["192.168.0.1"]
        }
      ]

      devices = [
        %{
          uid: "sr:farm01",
          ip: "192.168.2.1",
          name: "farm01",
          hostname: "farm01",
          type: "router",
          type_id: 12
        },
        %{
          uid: "sr:tonka01",
          ip: "192.168.10.1",
          name: "tonka01",
          hostname: "tonka01",
          type: "router",
          type_id: 12
        }
      ]

      [inferred] =
        MapperResultsIngestor.infer_wireguard_tunnel_links(records, interfaces, devices)

      assert inferred.protocol == "wireguard-derived"
      assert inferred.local_device_id == "sr:farm01"
      assert inferred.neighbor_device_id == "sr:tonka01"
      assert inferred.local_if_name == "wgsts1000"
      assert inferred.metadata["source"] == "wireguard-derived"
      assert inferred.metadata["evidence_class"] == "direct"
      assert inferred.metadata["tunnel_name"] == "wgsts1000"
    end

    test "does not add duplicate wireguard edges when one already exists" do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      records = [
        %{
          timestamp: now,
          agent_id: "agent-1",
          gateway_id: "gw-1",
          partition: "default",
          protocol: "wireguard",
          local_device_id: "sr:farm01",
          local_device_ip: "192.168.2.1",
          neighbor_device_id: "sr:tonka01",
          neighbor_mgmt_addr: "192.168.10.1"
        }
      ]

      interfaces = [
        %{
          device_id: "sr:farm01",
          timestamp: now,
          if_name: "wgsts1000",
          if_descr: nil,
          ip_addresses: ["192.168.0.0"]
        },
        %{
          device_id: "sr:tonka01",
          timestamp: now,
          if_name: "wgsts1000",
          if_descr: nil,
          ip_addresses: ["192.168.0.1"]
        }
      ]

      devices = [
        %{
          uid: "sr:farm01",
          ip: "192.168.2.1",
          name: "farm01",
          hostname: "farm01",
          type: "router",
          type_id: 12
        },
        %{
          uid: "sr:tonka01",
          ip: "192.168.10.1",
          name: "tonka01",
          hostname: "tonka01",
          type: "router",
          type_id: 12
        }
      ]

      assert MapperResultsIngestor.infer_wireguard_tunnel_links(records, interfaces, devices) ==
               []
    end
  end

  describe "topology metric bootstrap helpers" do
    test "topology_metric_bootstrap_targets/1 returns unique positive if_index targets" do
      records = [
        %{local_device_id: "sr:uswagg", local_if_index: 8},
        %{"local_device_id" => "sr:uswagg", "local_if_index" => 8},
        %{local_device_id: "sr:uswpro24-a", local_if_index: 19},
        %{local_device_id: "sr:bad", local_if_index: 0},
        %{local_device_id: nil, local_if_index: 7}
      ]

      assert MapSet.new(MapperResultsIngestor.topology_metric_bootstrap_targets(records)) ==
               MapSet.new([{"sr:uswagg", 8}, {"sr:uswpro24-a", 19}])
    end

    test "topology_metric_bootstrap_enabled?/2 honors metadata override" do
      records = [
        %{
          metadata: %{
            "topology_interface_metrics_autobootstrap_enabled" => "false"
          }
        }
      ]

      assert MapperResultsIngestor.topology_metric_bootstrap_enabled?(records, true) == false
      assert MapperResultsIngestor.topology_metric_bootstrap_enabled?(records, false) == false
    end

    test "merge_required_topology_metrics/1 adds required metrics without duplication" do
      selected =
        MapperResultsIngestor.merge_required_topology_metrics([
          "ifInOctets",
          "ifHCInOctets",
          "ifOutOctets"
        ])

      assert "ifInOctets" in selected
      assert "ifInUcastPkts" in selected
      assert "ifOutOctets" in selected
      assert "ifOutUcastPkts" in selected
      assert Enum.count(selected, &(&1 == "ifInOctets")) == 1
      assert Enum.count(selected, &(&1 == "ifOutOctets")) == 1
      assert "ifHCInOctets" in selected
    end

    test "merge_required_topology_metrics/2 adds HC metrics when interface supports them" do
      interface = %{
        available_metrics: [
          %{"name" => "ifInOctets"},
          %{"name" => "ifOutOctets"},
          %{"name" => "ifHCInOctets"},
          %{"name" => "ifHCOutOctets"}
        ]
      }

      selected = MapperResultsIngestor.merge_required_topology_metrics([], interface)

      assert "ifInOctets" in selected
      assert "ifOutOctets" in selected
      assert "ifHCInOctets" in selected
      assert "ifHCOutOctets" in selected
      assert "ifHCInUcastPkts" in selected
      assert "ifHCOutUcastPkts" in selected
    end

    test "merge_required_topology_metrics is idempotent for already-configured selections" do
      initial = [
        "ifInOctets",
        "ifOutOctets",
        "ifInUcastPkts",
        "ifOutUcastPkts",
        "ifHCInOctets"
      ]

      once = MapperResultsIngestor.merge_required_topology_metrics(initial)
      twice = MapperResultsIngestor.merge_required_topology_metrics(once)

      assert twice == once
    end

    test "topology_interface_settings_patch/2 returns no-op when already enabled and complete" do
      existing = %{
        metrics_enabled: true,
        metrics_selected: ["ifInOctets", "ifOutOctets", "ifInUcastPkts", "ifOutUcastPkts"]
      }

      assert MapperResultsIngestor.topology_interface_settings_patch(existing, nil) == nil
    end

    test "topology_interface_settings_patch/2 enables metrics when disabled" do
      existing = %{
        metrics_enabled: false,
        metrics_selected: ["ifInOctets", "ifOutOctets", "ifInUcastPkts", "ifOutUcastPkts"]
      }

      assert MapperResultsIngestor.topology_interface_settings_patch(existing, nil) == %{
               metrics_enabled: true,
               metrics_selected: ["ifInOctets", "ifOutOctets", "ifInUcastPkts", "ifOutUcastPkts"]
             }
    end

    test "topology_interface_settings_patch/2 reconciles missing metrics and keeps existing extras" do
      existing = %{metrics_enabled: true, metrics_selected: ["ifHCInOctets"]}

      assert MapperResultsIngestor.topology_interface_settings_patch(existing, nil) == %{
               metrics_enabled: true,
               metrics_selected: [
                 "ifHCInOctets",
                 "ifInOctets",
                 "ifInUcastPkts",
                 "ifOutOctets",
                 "ifOutUcastPkts"
               ]
             }
    end
  end
end
