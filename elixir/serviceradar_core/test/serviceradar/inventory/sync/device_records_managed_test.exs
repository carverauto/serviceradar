defmodule ServiceRadar.Inventory.Sync.DeviceRecordsManagedTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Inventory.Sync.DeviceRecords
  alias ServiceRadar.Inventory.Sync.Normalize

  test "honours explicit is_managed from a plugin inventory update" do
    timestamp = ~U[2026-08-29 17:00:00Z]

    unmanaged =
      Normalize.normalize_update(%{
        "ip" => "10.0.0.2",
        "hostname" => "inactive-sw",
        "source" => "opentext-nom",
        "is_managed" => false,
        "os" => %{"name" => "ArubaOS-CX", "version" => "FL.10.13.1161"},
        "hw_info" => %{"serial_number" => "ABC123", "memory_bytes" => 1024},
        "metadata" => %{"vendor_name" => "Aruba", "model" => "6300M", "device_type" => "Switch"}
      })

    [record] = DeviceRecords.build_device_upsert_records([{unmanaged, "dev-1"}], timestamp)
    assert record.is_managed == false
    assert record.os["name"] == "ArubaOS-CX"
    assert record.os["version"] == "FL.10.13.1161"
    assert record.hw_info["serial_number"] == "ABC123"
    assert record.hw_info["memory_bytes"] == 1024
    assert record.vendor_name == "Aruba"
  end

  test "keeps the previous default when a source does not speak to is_managed" do
    timestamp = ~U[2026-08-29 17:00:00Z]

    update =
      Normalize.normalize_update(%{
        "ip" => "10.0.0.3",
        "hostname" => "sweep-host",
        "source" => "sweep"
      })

    [record] = DeviceRecords.build_device_upsert_records([{update, "dev-2"}], timestamp)
    assert record.is_managed == true
  end
end
