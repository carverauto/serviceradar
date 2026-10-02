defmodule ServiceRadar.Inventory.Remediation.SourceIdentityRepairTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Inventory.Remediation.SourceIdentityRepair

  test "classifies exactly one current source ID without approving mutation" do
    result =
      SourceIdentityRepair.classify_row(%{
        device_uid: "device-a",
        typed_ids: ["300", "100", "200"],
        current_ids: ["200"],
        merge_audit_count: 4
      })

    assert result.classification == "one_current_id"
    assert result.current_ids == ["200"]
    assert result.stale_ids == ["100", "300"]
    assert result.retirable_ids == []
    assert result.proposed_action == "review_stale_ids_after_absence_grace"
    assert result.merge_audit_count == 4
    refute result.apply_eligible
  end

  test "multiple current IDs remain unresolved source-alias candidates" do
    result =
      SourceIdentityRepair.classify_row(%{
        device_uid: "device-b",
        typed_ids: ["100", "200"],
        current_ids: ["200", "100"]
      })

    assert result.classification == "multiple_current_ids"
    assert result.current_ids == ["100", "200"]
    assert result.stale_ids == []
    refute result.apply_eligible
  end

  test "no current IDs are historical and still not delete-approved" do
    result =
      SourceIdentityRepair.classify_row(%{
        device_uid: "device-c",
        typed_ids: ["100", "200"],
        current_ids: []
      })

    assert result.classification == "no_current_ids"
    assert result.stale_ids == ["100", "200"]
    assert result.proposed_action == "review_historical_identity"
    refute result.apply_eligible
  end

  test "stale IDs the retirement rule admits are proposed for retirement" do
    result =
      SourceIdentityRepair.classify_row(%{
        device_uid: "device-d",
        typed_ids: ["100", "200", "300"],
        current_ids: ["300"],
        retirable_ids: ["200"]
      })

    assert result.classification == "one_current_id"
    assert result.stale_ids == ["100", "200"]
    assert result.retirable_ids == ["200"]
    assert result.proposed_action == "retire_stale_ids"
    assert result.apply_eligible
  end

  test "a record whose only ID is retirable is proposed for retirement" do
    result =
      SourceIdentityRepair.classify_row(%{
        device_uid: "device-e",
        typed_ids: ["100"],
        current_ids: [],
        retirable_ids: ["100"]
      })

    assert result.classification == "no_current_ids"
    assert result.retirable_ids == ["100"]
    assert result.proposed_action == "retire_stale_ids"
    assert result.apply_eligible
  end

  test "an ID the latest collection reported is never retirable" do
    result =
      SourceIdentityRepair.classify_row(%{
        device_uid: "device-f",
        typed_ids: ["100", "200"],
        current_ids: ["200"],
        retirable_ids: ["200"]
      })

    assert result.retirable_ids == []
    assert result.proposed_action == "review_stale_ids_after_absence_grace"
    refute result.apply_eligible
  end

  test "multiple current IDs stay in review while their stale IDs retire" do
    result =
      SourceIdentityRepair.classify_row(%{
        device_uid: "device-g",
        typed_ids: ["100", "200", "300"],
        current_ids: ["100", "200"],
        retirable_ids: ["300"]
      })

    assert result.classification == "multiple_current_ids"
    assert result.retirable_ids == ["300"]
    assert result.proposed_action == "manual_source_alias_or_overmerge_review"
    assert result.apply_eligible
  end
end
