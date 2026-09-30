defmodule ServiceRadar.Edge.SweepContractTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Edge.SweepContract

  @bundle String.duplicate("ab", 32)
  @snapshot String.duplicate("cd", 32)

  defp document(overrides \\ %{}) do
    Jason.encode!(%{
      "registry_epoch" => 7,
      "registry_snapshot_sha256" => @snapshot,
      "contracts" => [
        Map.merge(
          %{
            "contract_id" => "serviceradar.sweep.observation",
            "contract_version" => 1,
            "contract_bundle_sha256" => @bundle,
            "state" => "active",
            "route_profile" => "EDGE_RECORD_ROUTE_PROFILE_DURABLE_RECORDS_V1",
            "traffic_class" => "EDGE_RECORD_TRAFFIC_CLASS_BULK",
            "partition_rule" => "network_scope_v1",
            "cost_model_version" => 3
          },
          overrides
        )
      ]
    })
  end

  test "the active sweep entry gives the values a production capability signs" do
    assert {:ok, contract} = SweepContract.from_document(document())

    assert contract.contract_id == "serviceradar.sweep.observation"
    assert contract.contract_version == 1
    assert contract.contract_bundle_sha256 == Base.decode16!(@bundle, case: :lower)
    assert contract.registry_epoch == 7
    assert contract.registry_snapshot_sha256 == Base.decode16!(@snapshot, case: :lower)
    assert contract.cost_model_version == 3
    assert contract.max_projected_row_count == 10_000
    assert contract.max_projected_write_bytes == 10_000 * 2_048
  end

  test "a sweep entry that is not active, or not registered, gives no contract" do
    assert {:error, {:sweep_contract_not_active, :draining}} =
             SweepContract.from_document(document(%{"state" => "draining"}))

    assert {:error, :sweep_contract_not_registered} =
             SweepContract.from_document(document(%{"contract_version" => 2}))

    assert {:error, :sweep_contract_lane} =
             SweepContract.from_document(
               document(%{"traffic_class" => "EDGE_RECORD_TRAFFIC_CLASS_INTERACTIVE"})
             )
  end

  test "a missing or malformed document gives no contract" do
    assert {:error, :registry_not_configured} = SweepContract.from_document(nil)
    assert {:error, {:invalid_registry, _}} = SweepContract.from_document("{}")
  end
end
