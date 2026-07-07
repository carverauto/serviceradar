defmodule ServiceRadar.Inventory.SourceIdentityDriftTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Inventory.SourceIdentityDrift

  test "format_conflict_report counts categories and bounds examples" do
    conflicts = [
      %{
        source_type: "armis",
        source_id: "source-a",
        source_identifier_type: "armis_device_id",
        source_identifier_value: "100",
        device_uid: "sr:a",
        current_ip: "10.0.0.1",
        conflict_category: "metadata_identifier_disagreement"
      },
      %{
        source_type: "armis",
        source_id: "source-a",
        source_identifier_type: "armis_device_id",
        source_identifier_value: "101",
        device_uid: "sr:b",
        current_ip: "10.0.0.2",
        conflict_category: "split_typed_generic_identifier"
      },
      %{
        source_type: "armis",
        source_id: "source-a",
        source_identifier_type: "armis_device_id",
        source_identifier_value: "102",
        device_uid: "sr:c",
        current_ip: "10.0.0.3",
        conflict_category: "split_typed_generic_identifier"
      }
    ]

    report = SourceIdentityDrift.format_conflict_report(conflicts, 2)

    assert report["total_count"] == 3

    assert report["categories"] == %{
             "metadata_identifier_disagreement" => 1,
             "split_typed_generic_identifier" => 2
           }

    assert length(report["examples"]) == 2
    assert SourceIdentityDrift.conflict_count(report) == 3
  end
end
