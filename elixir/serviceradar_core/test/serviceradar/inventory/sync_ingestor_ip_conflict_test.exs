defmodule ServiceRadar.Inventory.SyncIngestorIpConflictTest do
  @moduledoc """
  Regression coverage for the active-IP unique-index conflict recovery path
  in `SyncIngestor.bulk_upsert_devices/1`.

  Without uid remapping, identifier rows would reference the abandoned
  `sr:NEW…` uid and trip the `device_identifiers_device_id_fkey` FK constraint
  during `bulk_upsert_identifiers/1`.
  """

  use ExUnit.Case, async: false

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.DeviceIdentifier
  alias ServiceRadar.Inventory.SyncIngestor
  alias ServiceRadar.TestSupport

  require Ash.Query

  @moduletag :integration

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    actor = SystemActor.system(:sync_ingestor_ip_conflict_test)
    {:ok, actor: actor}
  end

  test "remaps identifiers to canonical uid when active-IP conflict triggers retry", %{
    actor: actor
  } do
    ip = unique_test_ip()
    armis_id = "armis-#{System.unique_integer([:positive])}"

    {:ok, existing} =
      Device
      |> Ash.Changeset.for_create(:create, %{
        uid: "sr:" <> Ecto.UUID.generate(),
        hostname: "preexisting",
        ip: ip
      })
      |> Ash.create(actor: actor)

    update = %{
      "ip" => ip,
      "hostname" => "incoming",
      "source" => "agent",
      "metadata" => %{"armis_device_id" => armis_id}
    }

    assert :ok = SyncIngestor.ingest_updates([update], actor: actor)

    {:ok, devices_at_ip} =
      Device
      |> Ash.Query.filter(ip == ^ip and is_nil(deleted_at))
      |> Ash.read(actor: actor)

    devices_at_ip = List.wrap(devices_at_ip)
    assert length(devices_at_ip) == 1
    [%Device{uid: canonical_uid}] = devices_at_ip
    assert canonical_uid == existing.uid

    {:ok, identifiers} =
      DeviceIdentifier
      |> Ash.Query.filter(identifier_type == :armis_device_id and identifier_value == ^armis_id)
      |> Ash.read(actor: actor)

    identifiers = List.wrap(identifiers)
    assert Enum.any?(identifiers, fn ident -> ident.device_id == canonical_uid end)
    refute Enum.any?(identifiers, fn ident -> ident.device_id != canonical_uid end)
  end

  defp unique_test_ip do
    seed = System.unique_integer([:positive, :monotonic])
    third = rem(seed, 250) + 1
    fourth = rem(div(seed, 250), 250) + 1
    "100.124.#{third}.#{fourth}"
  end
end
