defmodule ServiceRadar.Identity.AliasEventsPerDeviceTest do
  @moduledoc """
  AliasEvents records a sighting on the sighted device's own alias row.

  Alias rows are per device: the unique key is device, type and value, so an address several
  devices held in turn carries a row of each. A sighting used to be recorded on whichever row of
  the address it read first, so one device's sightings could confirm another device's alias of
  an address it no longer held, and the sighted device never got a row of its own.
  """

  use ServiceRadar.DataCase, async: true

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Identity.AliasEvents
  alias ServiceRadar.Identity.DeviceAliasState
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.TestSupport

  require Ash.Query

  @moduletag :integration

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    {:ok, actor: SystemActor.system(:alias_events_per_device_test)}
  end

  test "a device seen at an address another device holds gets a row of its own", %{actor: actor} do
    ip = "203.0.113.10"
    {:ok, holder} = create_device(actor, "per-device-holder")
    {:ok, device} = create_device(actor, "per-device-sighted")

    {:ok, held} = create_alias_row(actor, holder.uid, ip)
    {:ok, held} = DeviceAliasState.confirm(held, actor: actor)

    sight(actor, device.uid, ip, 3)

    assert [%DeviceAliasState{state: :detected, sighting_count: 1}] =
             alias_rows(device.uid, ip, actor)

    assert [%DeviceAliasState{state: :confirmed, sighting_count: count}] =
             alias_rows(holder.uid, ip, actor)

    assert count == held.sighting_count
  end

  test "a device's sightings confirm its own row, not another device's", %{actor: actor} do
    ip = "203.0.113.11"
    {:ok, holder} = create_device(actor, "per-device-earlier")
    {:ok, device} = create_device(actor, "per-device-now")

    {:ok, _held} = create_alias_row(actor, holder.uid, ip)

    for _ <- 1..3, do: sight(actor, device.uid, ip, 3)

    assert [%DeviceAliasState{state: :confirmed, sighting_count: 3}] =
             alias_rows(device.uid, ip, actor)

    assert [%DeviceAliasState{state: :detected, sighting_count: 1}] =
             alias_rows(holder.uid, ip, actor)
  end

  test "a sighting updates only the sighted device's row", %{actor: actor} do
    ip = "198.51.100.10"
    {:ok, a} = create_device(actor, "per-device-a")
    {:ok, b} = create_device(actor, "per-device-b")

    # The other device's row is written first, sighted more often and has the lower device id, so
    # a reader that took any row of the address would reach it first.
    [other_id, device_id] = Enum.sort([a.uid, b.uid])

    {:ok, other_row} = create_alias_row(actor, other_id, ip)

    {:ok, _} =
      DeviceAliasState.record_sighting(other_row, %{confirm_threshold: 10}, actor: actor)

    {:ok, _own_row} = create_alias_row(actor, device_id, ip)

    sight(actor, device_id, ip, 10)

    assert [%DeviceAliasState{state: :detected, sighting_count: 2}] =
             alias_rows(device_id, ip, actor)

    assert [%DeviceAliasState{state: :detected, sighting_count: 2}] =
             alias_rows(other_id, ip, actor)
  end

  defp sight(actor, device_id, ip, confirm_threshold) do
    assert {:ok, _events} =
             AliasEvents.process_and_persist(
               [
                 %{
                   device_id: device_id,
                   partition: "default",
                   timestamp: DateTime.utc_now(),
                   metadata: %{
                     "_alias_last_seen_at" => DateTime.to_iso8601(DateTime.utc_now()),
                     "_alias_last_seen_ip" => ip
                   }
                 }
               ],
               actor: actor,
               confirm_threshold: confirm_threshold
             )
  end

  defp create_device(actor, hostname) do
    Device
    |> Ash.Changeset.for_create(:create, %{
      uid: "sr:" <> Ecto.UUID.generate(),
      hostname: hostname
    })
    |> Ash.create(actor: actor)
  end

  defp create_alias_row(actor, device_id, ip) do
    DeviceAliasState.create_detected(
      %{
        device_id: device_id,
        partition: "default",
        alias_type: :ip,
        alias_value: ip,
        metadata: %{"source" => "test"}
      },
      actor: actor
    )
  end

  defp alias_rows(device_id, ip, actor) do
    DeviceAliasState
    |> Ash.Query.filter(device_id == ^device_id and alias_type == :ip and alias_value == ^ip)
    |> Ash.read!(actor: actor)
  end
end
