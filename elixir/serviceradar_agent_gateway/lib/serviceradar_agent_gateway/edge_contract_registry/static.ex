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

  alias ServiceRadar.Edge.StreamRoute

  @snapshot_keys ~w(registry_epoch registry_snapshot_sha256 contracts)
  @contract_keys ~w(contract_id contract_version contract_bundle_sha256 state route_profile
                    traffic_class partition_rule cost_model_version)
  @states %{
    "candidate" => :candidate,
    "ready" => :ready,
    "active" => :active,
    "draining" => :draining,
    "retired" => :retired,
    "security_revoked" => :security_revoked
  }
  @max_u32 0xFFFFFFFF
  @max_u64 0xFFFFFFFFFFFFFFFF

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

  @doc "Parses a snapshot document. Public so the format is testable without application env."
  @spec parse(term()) :: {:ok, ServiceRadarAgentGateway.EdgeContractRegistry.snapshot()} | {:error, term()}
  def parse(raw) when raw in [nil, ""], do: {:error, :registry_not_configured}

  def parse(raw) when is_binary(raw) do
    with {:ok, doc} <- decode(raw),
         :ok <- exact_keys(doc, @snapshot_keys),
         {:ok, epoch} <- integer(doc["registry_epoch"], @max_u64),
         {:ok, digest} <- digest(doc["registry_snapshot_sha256"]),
         {:ok, contracts} <- contracts(doc["contracts"]) do
      {:ok, %{registry_epoch: epoch, registry_snapshot_sha256: digest, contracts: contracts}}
    else
      {:error, reason} -> {:error, {:invalid_registry, reason}}
    end
  end

  def parse(_raw), do: {:error, {:invalid_registry, :not_json}}

  defp decode(raw) do
    case Jason.decode(raw) do
      {:ok, %{} = doc} -> {:ok, doc}
      _ -> {:error, :not_json}
    end
  end

  defp contracts(list) when is_list(list) do
    Enum.reduce_while(list, {:ok, %{}}, fn item, {:ok, acc} ->
      with {:ok, entry} <- contract(item),
           key = {entry.contract_id, entry.contract_version},
           false <- Map.has_key?(acc, key) do
        {:cont, {:ok, Map.put(acc, key, entry)}}
      else
        true -> {:halt, {:error, :duplicate_contract}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp contracts(_), do: {:error, :contracts}

  defp contract(%{} = item) do
    with :ok <- exact_keys(item, @contract_keys),
         {:ok, id} <- contract_id(item["contract_id"]),
         {:ok, version} <- integer(item["contract_version"], @max_u32),
         {:ok, bundle} <- digest(item["contract_bundle_sha256"]),
         {:ok, state} <- lookup(@states, item["state"], :state),
         {:ok, {profile, class}} <- lane(item["route_profile"], item["traffic_class"]),
         {:ok, rule} <- partition_rule(item["partition_rule"]),
         {:ok, cost} <- integer(item["cost_model_version"], @max_u32) do
      {:ok,
       %{
         contract_id: id,
         contract_version: version,
         contract_bundle_sha256: bundle,
         state: state,
         route_profile: profile,
         traffic_class: class,
         partition_rule: rule,
         cost_model_version: cost
       }}
    end
  end

  defp contract(_), do: {:error, :contract}

  defp exact_keys(map, keys) do
    if Enum.sort(Map.keys(map)) == Enum.sort(keys), do: :ok, else: {:error, :keys}
  end

  defp contract_id(id) when is_binary(id) and id != "", do: {:ok, id}
  defp contract_id(_), do: {:error, :contract_id}

  defp integer(value, max) when is_integer(value) and value >= 1 and value <= max, do: {:ok, value}
  defp integer(_value, _max), do: {:error, :integer}

  defp digest(hex) when is_binary(hex) and byte_size(hex) == 64 do
    case Base.decode16(hex, case: :lower) do
      {:ok, bytes} -> {:ok, bytes}
      :error -> {:error, :digest}
    end
  end

  defp digest(_), do: {:error, :digest}

  defp lookup(map, key, reason) do
    case Map.fetch(map, key) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, reason}
    end
  end

  defp lane(profile, class) do
    case Enum.find(StreamRoute.active_lanes(), fn {p, c} ->
           Atom.to_string(p) == profile and Atom.to_string(c) == class
         end) do
      nil -> {:error, :route}
      pair -> {:ok, pair}
    end
  end

  defp partition_rule(rule) do
    case Enum.find(StreamRoute.partition_rules(), &(Atom.to_string(&1) == rule)) do
      nil -> {:error, :partition_rule}
      found -> {:ok, found}
    end
  end
end
