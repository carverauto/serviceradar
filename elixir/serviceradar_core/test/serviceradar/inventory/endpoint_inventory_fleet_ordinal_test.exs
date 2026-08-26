defmodule ServiceRadar.Inventory.EndpointInventoryFleetOrdinalTest do
  use ServiceRadar.DataCase, async: true

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.EndpointInventoryFleetOrdinal
  alias ServiceRadar.TestSupport

  @moduletag :integration

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    {:ok, actor: SystemActor.system(:endpoint_inventory_fleet_ordinal_test)}
  end

  test "allocates a stable ordinal for a device uid", %{actor: actor} do
    unique = System.unique_integer([:positive])
    device = create_device!(actor, "endpoint-fleet-ordinal-device-#{unique}")

    assert {:ok, ordinal} = EndpointInventoryFleetOrdinal.ensure_allocated(device.uid)
    assert is_integer(ordinal)
    assert ordinal > 0

    assert {:ok, ^ordinal} = EndpointInventoryFleetOrdinal.ensure_allocated(device.uid)
    assert EndpointInventoryFleetOrdinal.ordinal_for(device.uid) == ordinal
  end

  test "does not allocate ordinals for service component ids" do
    assert {:ok, nil} = EndpointInventoryFleetOrdinal.ensure_allocated("serviceradar:core-elx")
    assert EndpointInventoryFleetOrdinal.ordinal_for("serviceradar:core-elx") == nil
  end

  defp create_device!(actor, uid) do
    now = DateTime.utc_now()

    Device
    |> Ash.Changeset.for_create(
      :create,
      %{
        uid: uid,
        hostname: "#{uid}.local",
        type_id: 0,
        is_available: true,
        first_seen_time: now,
        last_seen_time: now
      },
      actor: actor
    )
    |> Ash.create!(actor: actor)
  end
end
