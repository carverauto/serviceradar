defmodule ServiceRadar.Edge.ContractRegistryDocument do
  @moduledoc """
  Parses the installation's edge-record contract registry document: the JSON snapshot that
  names the output contracts the gateway admits and the route each one pins.

  Core and the agent gateway read the SAME document (`SERVICERADAR_EDGE_RECORD_CONTRACT_REGISTRY`
  in core, `AGENT_GATEWAY_EDGE_RECORD_CONTRACT_REGISTRY` in the gateway) through this one parser,
  so the contract values core signs into a production capability cannot disagree with the values
  the gateway admits. See `ServiceRadarAgentGateway.EdgeContractRegistry.Static` for the format.

  Parsing is strict and fails closed: an unknown key, a duplicate `(contract_id,
  contract_version)`, an unknown lifecycle state, or a route or partition rule this installation
  cannot resolve makes the whole snapshot unavailable.
  """

  alias ServiceRadar.Edge.StreamRoute

  @type entry :: %{
          contract_id: String.t(),
          contract_version: pos_integer(),
          contract_bundle_sha256: <<_::256>>,
          state: atom(),
          route_profile: atom(),
          traffic_class: atom(),
          partition_rule: atom(),
          cost_model_version: pos_integer()
        }

  @type snapshot :: %{
          registry_epoch: pos_integer(),
          registry_snapshot_sha256: <<_::256>>,
          contracts: %{optional({String.t(), pos_integer()}) => entry()}
        }

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

  @doc "Parses a snapshot document. Public so the format is testable without application env."
  @spec parse(term()) :: {:ok, snapshot()} | {:error, term()}
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

  defp integer(value, max) when is_integer(value) and value >= 1 and value <= max,
    do: {:ok, value}

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
