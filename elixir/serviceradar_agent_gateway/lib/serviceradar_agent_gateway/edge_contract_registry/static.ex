defmodule ServiceRadarAgentGateway.EdgeContractRegistry.Static do
  @moduledoc """
  Installation-static `ServiceRadarAgentGateway.EdgeContractRegistry` source.

  The snapshot is a JSON document supplied per deployment through
  `AGENT_GATEWAY_EDGE_RECORD_CONTRACT_REGISTRY` (application env
  `:edge_record_contract_registry`). It is NOT the signed registry snapshot of tasks 1.10/1.11 and
  carries no signature: it names the contracts this gateway admits and the route each one pins,
  keyed by the existing `EdgeOutputContractRef` fields. Replacing it with a signed loader is a
  change of source behind the same behaviour.

      {
        "registry_epoch": 1,
        "registry_snapshot_sha256": "<64 lowercase hex>",
        "contracts": [
          {
            "contract_id": "...",
            "contract_version": 1,
            "contract_bundle_sha256": "<64 lowercase hex>",
            "state": "active",
            "route_profile": "EDGE_RECORD_ROUTE_PROFILE_DURABLE_RECORDS_V1",
            "traffic_class": "EDGE_RECORD_TRAFFIC_CLASS_BULK",
            "partition_rule": "network_scope_v1",
            "cost_model_version": 1
          }
        ]
      }

  Parsing is strict and fails closed. An unknown key, a duplicate `(contract_id,
  contract_version)`, a lifecycle state outside the six the spec names, or a route/partition rule
  this installation cannot resolve makes the WHOLE snapshot unavailable rather than dropping one
  entry: a partially understood registry would admit some contracts under rules nobody approved.
  Route profiles, traffic classes and partition rules are matched against
  `ServiceRadar.Edge.StreamRoute`'s deployment-active sets, so configuration cannot activate a
  route the platform has not provisioned, and no atom is created from input.
  """

  @behaviour ServiceRadarAgentGateway.EdgeContractRegistry

  alias ServiceRadar.Edge.ContractRegistryDocument

  @impl true
  def snapshot do
    raw = Application.get_env(:serviceradar_agent_gateway, :edge_record_contract_registry)
    cache_key = {__MODULE__, :snapshot}

    # Parsed once per distinct configuration, not per frame.
    case :persistent_term.get(cache_key, nil) do
      {^raw, result} ->
        result

      _ ->
        result = parse(raw)
        :persistent_term.put(cache_key, {raw, result})
        result
    end
  end

  @doc "Parses a snapshot document (`ServiceRadar.Edge.ContractRegistryDocument.parse/1`)."
  @spec parse(term()) :: {:ok, ServiceRadarAgentGateway.EdgeContractRegistry.snapshot()} | {:error, term()}
  def parse(raw), do: ContractRegistryDocument.parse(raw)
end
