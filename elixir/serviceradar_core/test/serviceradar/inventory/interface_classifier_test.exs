defmodule ServiceRadar.Inventory.InterfaceClassifierTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Inventory.InterfaceClassificationRule
  alias ServiceRadar.Inventory.InterfaceClassifier

  test "classifies wireguard interfaces by name" do
    rule = %InterfaceClassificationRule{
      name: "wireguard",
      enabled: true,
      priority: 90,
      if_name_pattern: "(?i)^wg",
      classifications: ["vpn", "wireguard"]
    }

    record = %{
      device_id: "sr:wg-1",
      if_name: "wgsts1000",
      if_descr: "",
      if_alias: nil,
      if_type: 131,
      ip_addresses: ["192.168.0.1"],
      device_ip: "192.168.0.1"
    }

    [classified] = InterfaceClassifier.classify_records([record], [rule], %{})

    assert Enum.sort(classified.classifications) == ["vpn", "wireguard"]
  end

  test "classifies ubiquiti management interfaces by vendor and description" do
    rule = %InterfaceClassificationRule{
      name: "ubiquiti_mgmt",
      enabled: true,
      priority: 100,
      vendor_pattern: "(?i)ubiquiti|unifi",
      if_descr_pattern: "(?i)Annapurna Labs Ltd\\..*Ethernet Adapter",
      classifications: ["management"]
    }

    record = %{
      device_id: "sr:ubnt-1",
      if_name: "eth8",
      if_descr: "Annapurna Labs Ltd. Gigabit Ethernet Adapter",
      if_alias: nil,
      if_type: 6,
      ip_addresses: ["216.17.46.98"]
    }

    device_contexts = %{
      "sr:ubnt-1" => %{vendor_name: "Ubiquiti", model: "UDM-Pro"}
    }

    [classified] = InterfaceClassifier.classify_records([record], [rule], device_contexts)

    assert classified.classifications == ["management"]
  end

  test "uses highest-priority exclusive classification" do
    high = %InterfaceClassificationRule{
      name: "management_high",
      enabled: true,
      priority: 100,
      if_descr_pattern: "Adapter",
      classifications: ["management"]
    }

    low = %InterfaceClassificationRule{
      name: "wan_low",
      enabled: true,
      priority: 10,
      if_descr_pattern: "Adapter",
      classifications: ["wan"]
    }

    record = %{
      device_id: "sr:priority-1",
      if_name: "eth0",
      if_descr: "Adapter",
      if_alias: nil,
      if_type: 6,
      ip_addresses: ["10.0.0.1"]
    }

    [classified] = InterfaceClassifier.classify_records([record], [low, high], %{})

    assert classified.classifications == ["management"]
  end
end
