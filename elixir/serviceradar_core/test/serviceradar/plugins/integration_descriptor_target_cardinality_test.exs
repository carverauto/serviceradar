defmodule ServiceRadar.Plugins.IntegrationDescriptorTargetCardinalityTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Plugins.IntegrationDescriptor
  alias ServiceRadar.TestSupport.CredentialIntegrationFixtures

  test "a consumer defaults to per_target cardinality" do
    assert {:ok, consumer} = validated_consumer(&Map.delete(&1, "target_cardinality"))
    assert consumer["target_cardinality"] == "per_target"
  end

  test "a consumer may declare single cardinality" do
    assert {:ok, consumer} = validated_consumer(& &1)
    assert consumer["target_cardinality"] == "single"
  end

  test "an unrecognized cardinality is rejected rather than silently ignored" do
    assert {:error, errors} =
             validated_consumer(&Map.put(&1, "target_cardinality", "per_chunk"))

    assert Enum.any?(errors, &String.contains?(&1, "target_cardinality"))
  end

  test "a single-cardinality profile may not offer a scope wider than one agent" do
    # A gateway or partition scope admits every agent underneath it, and the
    # materializer reconciles each one separately, so the consumer's
    # whole-instance run would be delivered once per agent. The rule form
    # renders and validates its scope control from this list, so this is where
    # a widened form is caught.
    assert {:error, errors} = validated_profile(&Map.put(&1, "scope_types", ~w(agent gateway)))

    assert Enum.any?(errors, &String.contains?(&1, "scope_types"))
  end

  test "a per_target profile keeps the wider scopes" do
    assert {:ok, profile} =
             validated_profile(fn profile ->
               profile
               |> Map.put("scope_types", ~w(agent gateway))
               |> update_in(
                 ["provisioning", "consumers"],
                 &Enum.map(&1, fn consumer -> Map.delete(consumer, "target_cardinality") end)
               )
             end)

    assert profile["scope_types"] == ~w(agent gateway)
  end

  defp validated_consumer(transform) do
    result =
      validated_profile(fn profile ->
        update_in(profile, ["provisioning", "consumers"], &Enum.map(&1, transform))
      end)

    case result do
      {:ok, profile} ->
        [consumer] = profile["provisioning"]["consumers"]
        {:ok, consumer}

      {:error, errors} ->
        {:error, errors}
    end
  end

  defp validated_profile(transform) do
    descriptor =
      "netbox"
      |> CredentialIntegrationFixtures.raw_integrations!()
      |> update_in(["credential_profiles", Access.at(0)], transform)

    case IntegrationDescriptor.validate(descriptor, []) do
      {:ok, %{"credential_profiles" => [profile]}} -> {:ok, profile}
      {:error, errors} -> {:error, errors}
    end
  end
end
