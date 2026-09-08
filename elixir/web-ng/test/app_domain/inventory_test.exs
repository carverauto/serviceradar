defmodule ServiceRadarWebNG.InventoryTest do
  use ServiceRadarWebNG.DataCase, async: true

  import ServiceRadarWebNG.AshTestHelpers, only: [system_actor: 0]

  alias ServiceRadar.Inventory.Device
  alias ServiceRadarWebNG.Repo

  test "list_devices returns devices ordered by last_seen_time desc" do
    suffix = System.unique_integer([:positive])
    uid1 = "test-device-1-#{suffix}"
    uid2 = "test-device-2-#{suffix}"

    # Insert devices using raw SQL (needed until DeviceGroup migration is complete)
    Repo.insert_all("ocsf_devices", [
      %{
        uid: uid1,
        type_id: 0,
        hostname: "a",
        last_seen_time: ~U[2100-01-01 00:00:00Z]
      },
      %{
        uid: uid2,
        type_id: 0,
        hostname: "b",
        last_seen_time: ~U[2100-02-01 00:00:00Z]
      }
    ])

    # Query using Ash directly (the old ServiceRadarWebNG.Inventory context was removed).
    devices =
      Device
      |> Ash.Query.sort(last_seen_time: :desc)
      |> Ash.Query.limit(1_000)
      |> Ash.read!(actor: system_actor())

    devices =
      case devices do
        %Ash.Page.Keyset{results: results} -> results
        results when is_list(results) -> results
      end

    uids = Enum.map(devices, & &1.uid)

    assert uid2 in uids
    assert uid1 in uids

    assert Enum.find_index(uids, &(&1 == uid2)) <
             Enum.find_index(uids, &(&1 == uid1))
  end
end
