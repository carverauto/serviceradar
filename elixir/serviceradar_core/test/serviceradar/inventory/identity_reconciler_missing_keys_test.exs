defmodule ServiceRadar.Inventory.IdentityReconcilerMissingKeysTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Inventory.IdentityReconciler

  test "does not raise when identifiers map is missing optional strong keys" do
    ids = %{
      mac: "0CEA1432D27F",
      ip: "",
      partition: "default"
    }

    assert IdentityReconciler.has_strong_identifier?(ids)
    assert {:mac, "0CEA1432D27F"} = IdentityReconciler.highest_priority_identifier(ids)

    # Should not raise; returns a deterministic UUID string.
    device_id = IdentityReconciler.generate_deterministic_device_id(ids)
    assert is_binary(device_id)
    assert String.starts_with?(device_id, "sr:")
  end
end

