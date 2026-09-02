defmodule ServiceRadar.Inventory.Sync.EnrichmentHwInfoTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Inventory.Sync.Enrichment

  test "reads nested hw_info and firmware/os aliases from plugin metadata" do
    hw_info =
      Enrichment.infer_hw_info(%{
        "serial_number" => "VN4BM3P0W5",
        "firmware_version" => "FL.10.13.1161",
        "hw_info" => %{
          "processor" => "PowerPC405",
          "memory_bytes" => 7_973_057_331,
          "total_ports" => 120,
          "free_ports" => 11,
          "driver_name" => "ArubaOS-CX",
          "chassis_serials" => ["VN4BM3P0W5", "VN4BM3P0X3"]
        }
      })

    assert hw_info["serial_number"] == "VN4BM3P0W5"
    assert hw_info["processor"] == "PowerPC405"
    assert hw_info["memory_bytes"] == 7_973_057_331
    assert hw_info["total_ports"] == 120
    assert hw_info["driver_name"] == "ArubaOS-CX"
    assert hw_info["firmware_version"] == "FL.10.13.1161"
    assert hw_info["chassis_serials"] == ["VN4BM3P0W5", "VN4BM3P0X3"]
  end
end
