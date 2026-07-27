defmodule ServiceRadar.Plugins.PolicyOwnedAssignmentRecovery.OwnerReferenceTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Plugins.PolicyOwnedAssignmentRecovery.OwnerReference

  test "parses arbitrary bounded package credential purposes without creating atoms" do
    rule_id = Ash.UUID.generate()

    assert {:ok, owner} =
             OwnerReference.parse("network-credential-rule:#{rule_id}:configuration_read")

    assert owner == %{
             kind: :credential_rule,
             id: rule_id,
             purpose: "configuration_read"
           }

    assert OwnerReference.matches_request?(%{
             legacy_policy_id: "network-credential-rule:#{rule_id}:configuration_read",
             owner_kind: :credential_rule,
             owner_id: rule_id,
             owner_purpose: "configuration_read"
           })
  end

  test "preserves the historical default purpose for legacy policy ids" do
    rule_id = Ash.UUID.generate()

    assert {:ok, %{kind: :credential_rule, id: ^rule_id, purpose: "inventory_enrichment"}} =
             OwnerReference.parse("network-credential-rule:#{rule_id}")
  end

  test "rejects unsafe or unbounded purpose identifiers" do
    rule_id = Ash.UUID.generate()

    for purpose <- [
          "Uppercase",
          "contains:separator",
          "contains whitespace",
          String.duplicate("a", 129)
        ] do
      assert {:error, :invalid_policy_owner} =
               OwnerReference.parse("network-credential-rule:#{rule_id}:#{purpose}")
    end
  end
end
