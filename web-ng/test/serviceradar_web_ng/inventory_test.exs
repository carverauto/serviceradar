defmodule ServiceRadarWebNG.InventoryTest do
  use ServiceRadarWebNG.DataCase, async: true

  alias ServiceRadarWebNG.Inventory
  alias ServiceRadarWebNG.Repo

  test "list_devices returns devices ordered by last_seen desc" do
    Repo.insert_all("unified_devices", [
      %{
        device_id: "test-device-1",
        hostname: "a",
        last_seen: ~U[2025-01-01 00:00:00Z]
      },
      %{
        device_id: "test-device-2",
        hostname: "b",
        last_seen: ~U[2025-02-01 00:00:00Z]
      }
    ])

    devices = Inventory.list_devices(limit: 10)
    ids = Enum.map(devices, & &1.id)

    assert "test-device-2" in ids
    assert "test-device-1" in ids

    assert Enum.find_index(ids, &(&1 == "test-device-2")) <
             Enum.find_index(ids, &(&1 == "test-device-1"))
  end
end
