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

  defp validated_consumer(transform) do
    descriptor =
      "netbox"
      |> CredentialIntegrationFixtures.raw_integrations!()
      |> update_in(
        ["credential_profiles", Access.at(0), "provisioning", "consumers"],
        &Enum.map(&1, transform)
      )

    case IntegrationDescriptor.validate(descriptor, []) do
      {:ok, %{"credential_profiles" => [profile]}} ->
        [consumer] = profile["provisioning"]["consumers"]
        {:ok, consumer}

      {:error, errors} ->
        {:error, errors}
    end
  end
end
