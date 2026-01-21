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
end
