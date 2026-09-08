defmodule ServiceRadar.Inventory.SyncIngestorSourceLinkageTest do
  @moduledoc false

  use ServiceRadar.DataCase, async: true

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Ash.Page
  alias ServiceRadar.Identity.IdentityCache
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

  test "sync ingestor persists sync_service_id on integration devices and identifiers", %{
    actor: actor
  } do
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
        "integration_id" => armis_id,
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

  # Armis identity is partition-scoped by sync source: `Ids.identifier_partition/2` builds
  # "<partition>:armis:<sync_service_id>" whenever an update carries one. An update WITHOUT a
  # sync_service_id therefore lands in a different partition than the same device WITH one,
  # and the two are distinct identities by design -- the same Armis id served by two sync
  # sources is two devices, not one.
  #
  # So an already-stored identifier does not gain linkage metadata in place. It cannot: the
  # lookup that would find it searches the scoped partition and misses. Production handled the
  # one-time transition with a migration
  # (priv/repo/migrations/20260721210000_scope_armis_identifier_partitions.exs), which moved
  # rows that already HAD a sync_service_id; rows that never had one stay unscoped, and a
  # later linked sync forks them, as asserted below.
  #
  # This replaces an assertion that the ingestor backfills the existing row, which was true
  # until ae1a47a05 ("test: add hermetic Armis DIRE E2E coverage") introduced source scoping
  # nine days after this suite was written. Nothing caught it because the integration tier was
  # not running in CI.
  test "an Armis identifier that gains a sync_service_id forks into a source-scoped partition",
       %{actor: actor} do
    armis_id = "armis-#{System.unique_integer([:positive])}"
    sync_service_id = Ash.UUID.generate()
    ip = "10.12.0.#{unique_octet()}"
    mac = unique_mac()

    unlinked_update = %{
      "ip" => ip,
      "mac" => mac,
      "hostname" => "armis-existing-identifier",
      "source" => "armis",
      "metadata" => %{
        "armis_device_id" => armis_id,
        "integration_id" => armis_id,
        "integration_type" => "armis"
      }
    }

    linked_update =
      Map.put(unlinked_update, "sync_meta", %{"sync_service_id" => sync_service_id})

    assert :ok = SyncIngestor.ingest_updates([unlinked_update], actor: actor)
    assert :ok = SyncIngestor.ingest_updates([linked_update], actor: actor)

    {:ok, identifiers} =
      DeviceIdentifier
      |> Ash.Query.filter(identifier_type == :armis_device_id and identifier_value == ^armis_id)
      |> Ash.read(actor: actor)

    assert [unscoped, scoped] = Enum.sort_by(identifiers, & &1.partition)

    assert unscoped.partition == "default"
    assert scoped.partition == "default:armis:#{sync_service_id}"

    # The pre-existing row is left exactly as it was. Asserting the absence is the point:
    # a regression that "helpfully" backfilled linkage here would silently merge two sync
    # sources into one identity.
    assert unscoped.metadata["sync_service_id"] == nil
    assert unscoped.metadata["integration_type"] == "armis"

    assert scoped.metadata["sync_service_id"] == sync_service_id
    assert scoped.metadata["integration_type"] == "armis"

    refute scoped.device_id == unscoped.device_id
  end

  test "re-ingesting a linked Armis device updates the identifier it already owns", %{
    actor: actor
  } do
    armis_id = "armis-#{System.unique_integer([:positive])}"
    sync_service_id = Ash.UUID.generate()
    ip = "10.14.0.#{unique_octet()}"
    mac = unique_mac()
    serial = "SR#{System.unique_integer([:positive])}"

    linked_update = %{
      "ip" => ip,
      "mac" => mac,
      "hostname" => "armis-linked-identifier",
      "source" => "armis",
      "metadata" => %{
        "armis_device_id" => armis_id,
        "integration_id" => armis_id,
        "integration_type" => "armis"
      },
      "sync_meta" => %{
        "sync_service_id" => sync_service_id
      }
    }

    # Same sync source, so the same partition, so the same identifier row. The second update
    # adds hardware-serial evidence, which build_identifier_metadata/1 folds into the stored
    # metadata -- this is the metadata refresh the upsert's
    # `on_conflict: {:replace, [:last_seen, :metadata]}` exists to perform. "Dell" has to be a
    # vendor HardwareSerial.canonical_vendor/1 recognises, or the evidence is discarded and
    # the metadata never changes.
    enriched_update =
      update_in(linked_update, ["metadata"], fn metadata ->
        Map.merge(metadata, %{"serial_number" => serial, "vendor_name" => "Dell"})
      end)

    assert :ok = SyncIngestor.ingest_updates([linked_update], actor: actor)
    assert :ok = SyncIngestor.ingest_updates([enriched_update], actor: actor)

    {:ok, identifiers} =
      DeviceIdentifier
      |> Ash.Query.filter(identifier_type == :armis_device_id and identifier_value == ^armis_id)
      |> Ash.read(actor: actor)

    assert [%DeviceIdentifier{} = identifier] = identifiers
    assert identifier.partition == "default:armis:#{sync_service_id}"
    assert identifier.metadata["sync_service_id"] == sync_service_id
    assert identifier.metadata["integration_type"] == "armis"
    assert identifier.metadata["hardware_serial_normalized"]
  end

  test "sync ingestor invalidates stale IP identity cache entries after bulk upsert", %{
    actor: actor
  } do
    armis_id = "armis-#{System.unique_integer([:positive])}"
    ip = "10.13.0.#{unique_octet()}"

    IdentityCache.put(ip, %{
      canonical_device_id: "sr:stale-cache-entry",
      partition: "default",
      metadata_hash: nil,
      attributes: %{"ip" => ip},
      updated_at: DateTime.utc_now()
    })

    assert :ok =
             SyncIngestor.ingest_updates(
               [
                 %{
                   "ip" => ip,
                   "mac" => unique_mac(),
                   "hostname" => "armis-cache-invalidated",
                   "source" => "armis",
                   "metadata" => %{
                     "armis_device_id" => armis_id,
                     "integration_type" => "armis"
                   }
                 }
               ],
               actor: actor
             )

    assert IdentityCache.get(ip) == nil
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
