defmodule ServiceRadar.Inventory.Remediation.ArmisSourceIdentityRepairTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Inventory.Remediation.ArmisSourceIdentityRepair

  test "classifies exactly one current source ID without approving mutation" do
    result =
      ArmisSourceIdentityRepair.classify_row(%{
        device_uid: "device-a",
        typed_ids: ["300", "100", "200"],
        current_ids: ["200"],
        merge_audit_count: 4
      })

    assert result.classification == "one_current_id"
    assert result.current_ids == ["200"]
    assert result.stale_ids == ["100", "300"]
    assert result.merge_audit_count == 4
    refute result.apply_eligible
  end

  test "multiple current IDs remain unresolved source-alias candidates" do
    result =
      ArmisSourceIdentityRepair.classify_row(%{
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
      ArmisSourceIdentityRepair.classify_row(%{
        device_uid: "device-c",
        typed_ids: ["100", "200"],
        current_ids: []
      })

    assert result.classification == "no_current_ids"
    assert result.stale_ids == ["100", "200"]
    refute result.apply_eligible
  end
end
