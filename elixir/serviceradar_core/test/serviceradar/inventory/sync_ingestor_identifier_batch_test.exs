defmodule ServiceRadar.Inventory.SyncIngestorIdentifierBatchTest do
  @moduledoc false

  use ServiceRadar.DataCase, async: true

  import Ecto.Query

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.DeviceIdentifier
  alias ServiceRadar.Inventory.IntegrationIdentity
  alias ServiceRadar.Inventory.SyncIngestor
  alias ServiceRadar.Repo

  @moduletag :integration

  # A device_identifiers row binds 9 parameters and one statement binds at most 65535, so one
  # insert holds at most 7281 rows. The single ingest batch below registers 7650: each update
  # reports 49 MACs besides its armis_device_id and integration_id.
  @devices 150
  @macs_per_device 49
  @rows_per_statement div(65_535, 9)

  setup_all do
    ServiceRadar.TestSupport.start_core!()
    :ok
  end

  test "a batch with more identifier rows than one statement can bind is written whole" do
    actor = SystemActor.system(:sync_ingestor_identifier_batch_test)
    run = System.unique_integer([:positive])
    # A partition of its own keeps the addresses below clear of every other test's devices.
    partition = "identifier-batch-#{run}"
    sync_service_id = Ash.UUID.generate()

    updates = Enum.map(1..@devices, &update(&1, run, partition, sync_service_id))

    assert :ok = SyncIngestor.ingest_updates(updates, actor: actor)

    assert Repo.one(
             from(device in Device,
               where: device.partition == ^partition and is_nil(device.deleted_at),
               select: count(device.uid)
             )
           ) == @devices

    armis_ids = Enum.map(1..@devices, &armis_id(&1, run))

    owners =
      Repo.all(
        from(identifier in DeviceIdentifier,
          where:
            identifier.identifier_type == :armis_device_id and
              identifier.identifier_value in ^armis_ids,
          select: identifier.device_id
        )
      )

    assert length(owners) == @devices
    assert owners |> Enum.uniq() |> length() == @devices

    mac_counts =
      Repo.all(
        from(identifier in DeviceIdentifier,
          where: identifier.device_id in ^owners and identifier.identifier_type == :mac,
          group_by: identifier.device_id,
          select: count(identifier.id)
        )
      )

    assert mac_counts == List.duplicate(@macs_per_device, @devices)

    identifier_rows =
      Repo.one(
        from(identifier in DeviceIdentifier,
          where: identifier.device_id in ^owners,
          select: count(identifier.id)
        )
      )

    # Every row the batch registered is present, and there are more of them than one statement
    # can bind, so the write really did take more than one statement.
    assert identifier_rows == @devices * (@macs_per_device + 2)
    assert identifier_rows > @rows_per_statement
  end

  defp update(i, run, partition, sync_service_id) do
    [mac | _] = macs = Enum.map(1..@macs_per_device, &mac(run, i, &1))

    %{
      "ip" => "198.51.100.#{i}",
      "mac" => mac,
      "hostname" => "identifier-batch-#{i}",
      "source" => "armis",
      "partition" => partition,
      "is_available" => true,
      "metadata" => %{
        "armis_device_id" => armis_id(i, run),
        "integration_id" =>
          IntegrationIdentity.scoped_device_id("armis", sync_service_id, armis_id(i, run)),
        "integration_type" => "armis",
        "mac_addresses" => Enum.join(macs, ",")
      },
      "sync_meta" => %{"sync_service_id" => sync_service_id}
    }
  end

  defp armis_id(i, run), do: "#{run}#{String.pad_leading(Integer.to_string(i), 3, "0")}"

  # Locally administered (first octet 02), so no vendor block: the run, the device and the MAC's
  # index make the remaining octets, which keeps every MAC distinct.
  defp mac(run, device, index) do
    Enum.map_join(
      [2, div(rem(run, 65_536), 256), rem(run, 256), div(device, 256), rem(device, 256), index],
      ":",
      &(&1 |> Integer.to_string(16) |> String.pad_leading(2, "0"))
    )
  end
end
