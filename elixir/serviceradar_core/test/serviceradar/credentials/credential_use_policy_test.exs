defmodule ServiceRadar.Credentials.CredentialUsePolicyTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Credentials.CredentialUsePolicy

  @actor %{
    id: "018f3f56-1111-7666-8777-123456789abc",
    role: :operator
  }

  test "missing policies deny credential use" do
    assert {:error, :credential_use_policy_missing} =
             CredentialUsePolicy.authorize_rule(%{metadata: %{}}, @actor)
  end

  test "an exact role selector authorizes the current actor" do
    assert :ok = CredentialUsePolicy.authorize(policy(roles: ["operator"]), @actor)
  end

  test "a persisted user struct is valid current credential-use authority" do
    actor = %ServiceRadar.Identity.User{id: @actor.id, role: :operator, status: :active}

    assert :ok = CredentialUsePolicy.authorize(policy(roles: ["operator"]), actor)
  end

  test "a principal selector may match the actor id or authenticated IdP subject" do
    assert :ok =
             CredentialUsePolicy.authorize(
               policy(principals: [@actor.id]),
               @actor
             )

    assert :ok =
             CredentialUsePolicy.authorize(
               policy(principals: ["oidc|console-user"]),
               @actor,
               %{"sub" => "oidc|console-user"}
             )
  end

  test "a group selector matches authenticated identity claims" do
    assert :ok =
             CredentialUsePolicy.authorize(
               policy(groups: ["pve-console-operators"]),
               @actor,
               %{"groups" => ["network-operators", "pve-console-operators"]}
             )
  end

  test "valid policies without a matching selector deny use" do
    assert {:error, :credential_use_policy_denied} =
             CredentialUsePolicy.authorize(policy(roles: ["admin"]), @actor)
  end

  test "unknown fields and malformed selectors fail closed as invalid" do
    assert {:error, :credential_use_policy_invalid} =
             CredentialUsePolicy.authorize(
               Map.put(policy(roles: ["operator"]), "allow_all", true),
               @actor
             )

    assert {:error, :credential_use_policy_invalid} =
             CredentialUsePolicy.authorize(policy(roles: "operator"), @actor)
  end

  test "unknown policy versions fail closed" do
    assert {:error, :credential_use_policy_invalid} =
             CredentialUsePolicy.authorize(
               %{"schema" => "serviceradar.credential_use_policy.v2", "roles" => ["operator"]},
               @actor
             )
  end

  test "system actors never satisfy end-user credential policy" do
    assert {:error, :credential_use_policy_denied} =
             CredentialUsePolicy.authorize(policy(roles: ["system"]), %{role: :system})

    assert {:error, :credential_use_policy_denied} =
             CredentialUsePolicy.authorize(policy(roles: ["system"]), %{"role" => :system})
  end

  defp policy(selectors) do
    Enum.reduce(selectors, %{"schema" => CredentialUsePolicy.schema()}, fn {key, value}, policy ->
      Map.put(policy, Atom.to_string(key), value)
    end)
  end
end
