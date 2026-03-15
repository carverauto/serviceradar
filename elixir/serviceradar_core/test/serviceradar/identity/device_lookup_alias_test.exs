defmodule ServiceRadar.Identity.DeviceLookupAliasTest do
  @moduledoc """
  Integration coverage for IP alias resolution in DeviceLookup.
  """

  use ExUnit.Case, async: false

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Identity.DeviceAliasState
  alias ServiceRadar.Identity.DeviceLookup
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.TestSupport

  @moduletag :integration

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    actor = SystemActor.system(:device_lookup_alias_test)
    {:ok, actor: actor}
  end

  test "batch lookup resolves confirmed IP aliases", %{actor: actor} do
    uid = "sr:" <> Ecto.UUID.generate()

    assert {:ok, _device} =
             Device
             |> Ash.Changeset.for_create(:create, %{
               uid: uid,
               ip: "216.17.46.98",
               hostname: "tonka01"
             })
             |> Ash.create(actor: actor)

    assert {:ok, alias_state} =
             DeviceAliasState.create_detected(
               %{
                 device_id: uid,
                 partition: "default",
                 alias_type: :ip,
                 alias_value: "192.168.10.1",
                 metadata: %{}
               },
               actor: actor
             )

    assert {:ok, _confirmed} =
             DeviceAliasState.record_sighting(
               alias_state,
               %{confirm_threshold: 1},
               actor: actor
             )

    result = DeviceLookup.batch_lookup_by_ip(["192.168.10.1"], actor: actor)

    assert result["192.168.10.1"].canonical_device_id == uid
  end
end
