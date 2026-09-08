defmodule ServiceRadar.Inventory.Identity.HardwareSerialTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Inventory.Identity.HardwareSerial
  alias ServiceRadar.Inventory.Identity.Ids

  test "canonical vendor aliases produce the same scoped serial" do
    for vendor <- ["Cisco", "Cisco Systems", "Cisco Systems, Inc."] do
      update = %{metadata: %{"vendor_name" => vendor, "serial_number" => "FOC-1234-ABC"}}
      assert HardwareSerial.from_update(update) == "cisco:FOC1234ABC"
    end

    for vendor <- ["Aruba", "Aruba Networks", "HPE Aruba", "Hewlett Packard Enterprise"] do
      update = %{metadata: %{"vendor_name" => vendor, "serial_number" => "CN12-34"}}
      assert HardwareSerial.from_update(update) == "hpe:CN1234"
    end
  end

  test "rejects untrusted vendors and unsafe serial values" do
    invalid = [
      {"Unknown Vendor", "ABC123"},
      {"Cisco", ""},
      {"Cisco", "unknown"},
      {"Cisco", "00000000"},
      {"Cisco", "AAAAAA"},
      {"Cisco", "ABC123,DEF456"},
      {"Cisco", "ABC 123"},
      {"Cisco", String.duplicate("A1", 65)}
    ]

    for {vendor, serial} <- invalid do
      update = %{metadata: %{"vendor_name" => vendor, "serial_number" => serial}}
      assert HardwareSerial.from_update(update) == nil
    end
  end

  test "extracts serial evidence from hw_info and adds it to DIRE priority" do
    ids =
      Ids.extract_strong_identifiers(%{
        metadata: %{"manufacturer" => "Juniper Networks"},
        hw_info: %{"serial_number" => "JN-12345"},
        partition: "default",
        ip: "192.0.2.10"
      })

    assert ids.hardware_serial == "juniper:JN12345"
    assert Ids.has_strong_identifier?(ids)
    assert Ids.highest_priority_identifier(ids) == {:hardware_serial, "juniper:JN12345"}
    assert :hardware_serial in Ids.identifier_priority()
  end
end
