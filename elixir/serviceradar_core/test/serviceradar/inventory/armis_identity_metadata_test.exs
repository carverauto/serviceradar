defmodule ServiceRadar.Inventory.ArmisIdentityMetadataTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Inventory.Identity.Ids
  alias ServiceRadar.Inventory.Sync.IdentifierRecords
  alias ServiceRadar.Inventory.Sync.Lookups
  alias ServiceRadar.Inventory.Sync.Normalize

  test "legacy Armis source_device_id is promoted to armis_device_id identity" do
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

    assert ids.armis_id == "39491"
    assert ids.integration_id == "39491"
    assert Ids.highest_priority_identifier(ids) == {:armis_device_id, "39491"}
  end

  test "bulk sync lookup and identifier records include Armis device IDs" do
    update =
      Normalize.normalize_update(%{
        "hostname" => "armis-cold",
        "source" => "armis",
        "metadata" => %{
          "integration_type" => "armis",
          "source_device_id" => "50000",
          "integration_id" => "50000"
        }
      })

    assert {:armis_device_id, "50000", "default"} in Lookups.extract_all_identifiers([update])

    records = IdentifierRecords.build_identifier_records([{update, "sr:test-device"}])

    assert Enum.any?(records, fn record ->
             record.identifier_type == :armis_device_id and
               record.identifier_value == "50000" and
               record.device_id == "sr:test-device"
           end)
  end
end
