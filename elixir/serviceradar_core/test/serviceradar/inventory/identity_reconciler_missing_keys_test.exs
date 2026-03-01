defmodule ServiceRadar.Inventory.IdentityReconcilerMissingKeysTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Inventory.IdentityReconciler

  test "extract_strong_identifiers picks up agent_id from top-level update when metadata is missing it" do
    agent_id = "agent-#{System.unique_integer([:positive])}"

    ids =
      IdentityReconciler.extract_strong_identifiers(%{
        agent_id: agent_id,
        ip: "10.0.0.1",
        mac: nil,
        partition: "default",
        metadata: %{}
      })

    assert ids.agent_id == agent_id
  end

  test "lookup_by_strong_identifiers does not raise when identifiers map is missing :agent_id key" do
    # This is a regression test for a KeyError seen in production when
    # identifier extraction omitted :agent_id entirely.
    ids = %{
      mac: "0CEA1432D27F",
      ip: "",
      partition: "default",
      armis_id: nil,
      integration_id: nil,
      netbox_id: nil
    }

    # No actor is required for this safety check; the function should never crash
    # due to optional/missing keys.
    assert {:ok, _} = IdentityReconciler.lookup_by_strong_identifiers(ids, nil)
  end

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
