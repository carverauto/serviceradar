defmodule ServiceRadarAgentGateway.TestSupport.EdgeContractRegistryStub do
  @moduledoc false

  # A registry holding exactly one active contract, matching `contract_ref/0`. A test overrides the
  # whole result with `Process.put(:edge_contract_registry_snapshot, result)`.

  @contract_id "serviceradar.test.sweep"
  @bundle :binary.copy(<<0xB1>>, 32)
  @snapshot_digest :binary.copy(<<0xB2>>, 32)

  def snapshot do
    case Process.get(:edge_contract_registry_snapshot) do
      nil -> {:ok, snapshot_with(:active)}
      result -> result
    end
  end

  def snapshot_with(state, overrides \\ %{}) do
    entry =
      Map.merge(
        %{
          contract_id: @contract_id,
          contract_version: 1,
          contract_bundle_sha256: @bundle,
          state: state,
          route_profile: :EDGE_RECORD_ROUTE_PROFILE_DURABLE_RECORDS_V1,
          traffic_class: :EDGE_RECORD_TRAFFIC_CLASS_BULK,
          partition_rule: :network_scope_v1,
          cost_model_version: 1
        },
        overrides
      )

    %{
      registry_epoch: 1,
      registry_snapshot_sha256: @snapshot_digest,
      contracts: %{{entry.contract_id, entry.contract_version} => entry}
    }
  end

  def contract_ref do
    %Serviceradar.Edge.V1.EdgeOutputContractRef{
      contract_id: @contract_id,
      contract_version: 1,
      contract_bundle_sha256: @bundle,
      registry_epoch: 1,
      registry_snapshot_sha256: @snapshot_digest,
      effective_grant_sha256: :binary.copy(<<0xB3>>, 32)
    }
  end
end
