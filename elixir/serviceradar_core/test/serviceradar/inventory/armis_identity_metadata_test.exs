defmodule ServiceRadar.Inventory.ArmisIdentityMetadataTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Inventory.Identity.Ids
  alias ServiceRadar.Inventory.Sync.IdentifierRecords
  alias ServiceRadar.Inventory.Sync.Lookups
  alias ServiceRadar.Inventory.Sync.Normalize
  alias ServiceRadar.Inventory.Sync.SourcePolicy

  test "self-scoped admission and unscoped rejection are provider-neutral" do
    for provider <- ["armis", "netbox", "test-integration", "future-provider"],
        source_id <- [nil, "source-a"] do
      scoped = "#{provider}:source-a:device:101"

      metadata = %{
        "integration_type" => provider,
        "integration_id" => scoped,
        "sync_service_id" => source_id
      }

      assert %{integration_id: ^scoped} = Ids.extract_strong_identifiers(%{metadata: metadata})

      unscoped = metadata |> Map.put("integration_id", "101") |> Map.delete("sync_service_id")
      assert %{integration_id: nil} = Ids.extract_strong_identifiers(%{metadata: unscoped})
    end
  end

  test "driver-owned bare IDs are not synthesized when a sync service is present" do
    for provider <- ["armis", "netbox"] do
      metadata = %{
        "integration_type" => provider,
        "integration_id" => "101",
        "sync_service_id" => "source-a"
      }

      assert %{integration_id: nil, legacy_integration_ids: []} =
               Ids.extract_strong_identifiers(%{metadata: metadata})
    end
  end

  test "legacy Armis source_device_id is not promoted to strong identity" do
    update =
      Normalize.normalize_update(%{
        "hostname" => "armis-legacy",
        "source" => "armis",
        "metadata" => %{
          "integration_type" => "armis",
          "source_device_id" => "39491",
          "integration_id" => "39491"
        }
      })

    ids = Ids.extract_strong_identifiers(update)

    assert ids.armis_id == nil
    assert ids.integration_id == nil
    assert Ids.highest_priority_identifier(ids) == {nil, nil}
  end

  test "bulk sync lookup and identifier records include Armis device IDs" do
    update =
      Normalize.normalize_update(%{
        "hostname" => "armis-cold",
        "source" => "armis",
        "metadata" => %{
          "integration_type" => "armis",
          "armis_device_id" => "18497",
          "source_device_id" => "50000",
          "integration_id" => "18497"
        }
      })

    ids = Ids.extract_strong_identifiers(update)

    assert {:armis_device_id, "18497", "default"} in Lookups.extract_all_identifiers([update])
    refute {:integration_id, "50000", "default"} in Lookups.extract_all_identifiers([update])

    records = IdentifierRecords.build_identifier_records([{update, "sr:test-device"}])

    assert Enum.any?(records, fn record ->
             record.identifier_type == :armis_device_id and
               record.identifier_value == "18497" and
               record.device_id == "sr:test-device"
           end)

    refute Enum.any?(records, fn record ->
             record.identifier_type == :integration_id
           end)

    # Policy check, mirroring how Lookups/IdentifierRecords derive `ids`:
    # Armis carries a typed, source-authoritative identifier, so its raw
    # integration_id must NOT also be offered as a device identity.
    ids = SourcePolicy.effective_identifiers(update)
    id_types = SourcePolicy.identifier_types(update, ids)

    assert :armis_device_id in id_types
    refute :integration_id in id_types
  end

  test "generic integration IDs are scoped by sync source and keep raw value lookup-only" do
    update =
      Normalize.normalize_update(%{
        "hostname" => "generic-source-device",
        "source" => "integration",
        "metadata" => %{
          "integration_type" => "test-integration",
          "integration_id" => "shared-device-42"
        },
        "sync_meta" => %{
          "sync_service_id" => "source-a"
        }
      })

    ids = Ids.extract_strong_identifiers(update)

    assert ids.integration_id == "test-integration:source:source-a:shared-device-42"
    assert ids.legacy_integration_ids == ["shared-device-42"]

    assert {:integration_id, "test-integration:source:source-a:shared-device-42", "default"} in Lookups.extract_all_identifiers(
             [update]
           )

    assert {:integration_id, "shared-device-42", "default"} in Lookups.extract_all_identifiers([
             update
           ])

    records = IdentifierRecords.build_identifier_records([{update, "sr:test-device"}])

    assert Enum.any?(records, fn record ->
             record.identifier_type == :integration_id and
               record.identifier_value == "test-integration:source:source-a:shared-device-42"
           end)

    refute Enum.any?(records, fn record ->
             record.identifier_type == :integration_id and
               record.identifier_value == "shared-device-42"
           end)
  end

  test "source-scoped Armis integration IDs resolve through the generic path" do
    update =
      Normalize.normalize_update(%{
        "hostname" => "armis-scoped",
        "source" => "armis",
        "metadata" => %{
          "integration_type" => "armis",
          "armis_device_id" => "18497",
          "integration_id" => "armis:source-a:device:18497"
        },
        "sync_meta" => %{"sync_service_id" => "source-a"}
      })

    ids = Ids.extract_strong_identifiers(update)

    assert ids.armis_id == "18497"
    assert ids.integration_id == "armis:source-a:device:18497"
    assert ids.partition == "default:armis:source-a"
    assert Ids.highest_priority_identifier(ids) == {:armis_device_id, "18497"}

    assert {:armis_device_id, "18497", "default:armis:source-a"} in Lookups.extract_all_identifiers(
             [
               update
             ]
           )

    assert {:integration_id, "armis:source-a:device:18497", "default:armis:source-a"} in Lookups.extract_all_identifiers(
             [
               update
             ]
           )

    records = IdentifierRecords.build_identifier_records([{update, "sr:test-device"}])

    assert Enum.any?(records, fn record ->
             record.identifier_type == :armis_device_id and
               record.identifier_value == "18497" and
               record.partition == "default:armis:source-a"
           end)

    assert Enum.any?(records, fn record ->
             record.identifier_type == :integration_id and
               record.identifier_value == "armis:source-a:device:18497" and
               record.partition == "default:armis:source-a"
           end)

    # Policy check, mirroring how Lookups/IdentifierRecords derive `ids`:
    # a scoped value carries its own provenance, so the generic type is
    # offered alongside the typed Armis identifier.
    ids = SourcePolicy.effective_identifiers(update)
    id_types = SourcePolicy.identifier_types(update, ids)

    assert :armis_device_id in id_types
    assert :integration_id in id_types
  end

  test "Armis typed identifiers are partition-scoped by sync source" do
    update =
      Normalize.normalize_update(%{
        "hostname" => "armis-source-scoped",
        "source" => "armis",
        "metadata" => %{
          "integration_type" => "armis",
          "armis_device_id" => "42",
          "integration_id" => "42"
        },
        "sync_meta" => %{"sync_service_id" => "source-a"}
      })

    ids = Ids.extract_strong_identifiers(update)

    assert ids.partition == "default:armis:source-a"

    assert {:armis_device_id, "42", "default:armis:source-a"} in Lookups.extract_all_identifiers([
             update
           ])

    records = IdentifierRecords.build_identifier_records([{update, "sr:test-device"}])

    assert Enum.any?(records, fn record ->
             record.identifier_type == :armis_device_id and
               record.identifier_value == "42" and
               record.partition == "default:armis:source-a"
           end)
  end
end
