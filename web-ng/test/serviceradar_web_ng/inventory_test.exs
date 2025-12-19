defmodule ServiceRadarWebNG.InventoryTest do
  use ServiceRadarWebNG.DataCase, async: true

  alias ServiceRadarWebNG.Inventory
  alias ServiceRadarWebNG.Repo

  test "list_devices returns devices ordered by last_seen_time desc" do
    Repo.insert_all("ocsf_devices", [
      %{
        uid: "test-device-1",
        type_id: 0,
        hostname: "a",
        last_seen_time: ~U[2025-01-01 00:00:00Z]
      },
      %{
        uid: "test-device-2",
        type_id: 0,
        hostname: "b",
        last_seen_time: ~U[2025-02-01 00:00:00Z]
      }
    ])

    devices = Inventory.list_devices(limit: 10)
    uids = Enum.map(devices, & &1.uid)

    assert "test-device-2" in uids
    assert "test-device-1" in uids

    assert Enum.find_index(uids, &(&1 == "test-device-2")) <
             Enum.find_index(uids, &(&1 == "test-device-1"))
  end
end
