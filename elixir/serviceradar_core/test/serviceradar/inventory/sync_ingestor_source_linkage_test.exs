defmodule ServiceRadar.Inventory.SyncIngestorSourceLinkageTest do
  @moduledoc false

  use ExUnit.Case, async: false

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Ash.Page
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.DeviceIdentifier
  alias ServiceRadar.Inventory.SyncIngestor

  require Ash.Query

  @moduletag :integration

  setup_all do
    ServiceRadar.TestSupport.start_core!()
    :ok
  end

  setup do
    actor = SystemActor.system(:sync_ingestor_source_linkage_test)
    {:ok, actor: actor}
  end

  test "sync ingestor persists sync_service_id on armis devices and identifiers", %{actor: actor} do
    armis_id = "armis-#{System.unique_integer([:positive])}"
    sync_service_id = Ash.UUID.generate()
    ip = "10.11.0.#{unique_octet()}"

    update = %{
      "ip" => ip,
      "mac" => unique_mac(),
      "hostname" => "armis-source-linked-device",
      "source" => "armis",
      "metadata" => %{
        "armis_device_id" => armis_id,
        "integration_type" => "armis"
      },
      "sync_meta" => %{
        "sync_service_id" => sync_service_id
      }
    }

    assert :ok = SyncIngestor.ingest_updates([update], actor: actor)

    {:ok, [device]} =
      Device
      |> Ash.Query.filter(ip == ^ip)
      |> Ash.read(actor: actor)
      |> Page.unwrap()

    assert device.metadata["sync_service_id"] == sync_service_id
    assert device.metadata["integration_type"] == "armis"
    assert device.metadata["armis_device_id"] == armis_id

    {:ok, identifiers} =
      DeviceIdentifier
      |> Ash.Query.filter(
        device_id == ^device.uid and identifier_type == :armis_device_id and
          identifier_value == ^armis_id
      )
      |> Ash.read(actor: actor)

    assert [%DeviceIdentifier{} = identifier] = identifiers
    assert identifier.metadata["sync_service_id"] == sync_service_id
    assert identifier.metadata["integration_type"] == "armis"
  end

  test "sync ingestor backfills metadata on existing armis identifiers", %{actor: actor} do
    armis_id = "armis-#{System.unique_integer([:positive])}"
    sync_service_id = Ash.UUID.generate()
    ip = "10.12.0.#{unique_octet()}"
    mac = unique_mac()

    initial_update = %{
      "ip" => ip,
      "mac" => mac,
      "hostname" => "armis-existing-identifier",
      "source" => "armis",
      "metadata" => %{
        "armis_device_id" => armis_id,
        "integration_type" => "armis"
      }
    }

    linked_update = %{
      "ip" => ip,
      "mac" => mac,
      "hostname" => "armis-existing-identifier",
      "source" => "armis",
      "metadata" => %{
        "armis_device_id" => armis_id,
        "integration_type" => "armis"
      },
      "sync_meta" => %{
        "sync_service_id" => sync_service_id
      }
    }

    assert :ok = SyncIngestor.ingest_updates([initial_update], actor: actor)
    assert :ok = SyncIngestor.ingest_updates([linked_update], actor: actor)

    {:ok, [device]} =
      Device
      |> Ash.Query.filter(ip == ^ip)
      |> Ash.read(actor: actor)
      |> Page.unwrap()

    {:ok, identifiers} =
      DeviceIdentifier
      |> Ash.Query.filter(
        device_id == ^device.uid and identifier_type == :armis_device_id and
          identifier_value == ^armis_id
      )
      |> Ash.read(actor: actor)

    assert [%DeviceIdentifier{} = identifier] = identifiers
    assert identifier.metadata["sync_service_id"] == sync_service_id
    assert identifier.metadata["integration_type"] == "armis"
  end

  defp unique_mac do
    suffix =
      [:positive]
      |> System.unique_integer()
      |> Integer.to_string(16)
      |> String.pad_leading(10, "0")

    suffix
    |> String.upcase()
    |> String.graphemes()
    |> Enum.chunk_every(2)
    |> Enum.map_join(":", &Enum.join/1)
    |> then(&"02:#{&1}")
  end

  defp unique_octet do
    [:positive]
    |> System.unique_integer()
    |> rem(200)
    |> Kernel.+(20)
  end
end
