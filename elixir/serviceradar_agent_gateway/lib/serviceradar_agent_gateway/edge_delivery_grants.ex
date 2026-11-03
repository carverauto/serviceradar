defmodule ServiceRadarAgentGateway.EdgeDeliveryGrants do
  @moduledoc """
  The gateway half of `RenewEdgeDeliveryGrants` (unify-sweep-results-proto M2.0g): a reconnecting
  agent names the spooled records whose production grant has lapsed, and gets back a delivery
  grant for each one core will grant.

  Core decides whether the authority a record names is still the agent's
  (`ServiceRadar.Edge.DeliveryGrants`), but it only sees the coordinates this module extracts. So
  every record is verified HERE first, from its exact bytes, against the authenticated agent and
  the installed trust snapshot (`EdgeRecordAuthorization.grant_subject/3`): it admits, its origin
  is this agent, its production grant verifies under a valid key, and its network scope is bound
  to the agent. The agent cannot obtain a grant for bytes it did not produce, or name another
  record's assignment.

  The request is bounded (`max_records/0`, `max_record_bytes/0`) so a renewal costs at most one
  ordinary credit window of verification. A record that fails verification, or that core refuses,
  is answered with a refusal; nothing about the record changes, and the agent delivers it without
  a grant, where the gateway decides it exactly as it would have.
  """

  alias ServiceRadar.Edge.DeliveryGrants
  alias ServiceRadarAgentGateway.CoreNodeForwarder
  alias ServiceRadarAgentGateway.EdgeRecordAuthorization
  alias ServiceRadarAgentGateway.EdgeRecordTrust

  require Logger

  @max_records 64
  @max_record_bytes 2 * 1024 * 1024
  @rpc_timeout_ms 10_000

  @doc "The most records one request may name."
  def max_records, do: @max_records

  @doc "The most record bytes one request may carry."
  def max_record_bytes, do: @max_record_bytes

  @doc """
  Answers one request for the authenticated `identity` (the resolved edge identity of the agent's
  certificate). Returns `{:ok, response}`, or `{:error, status, message}` for a request that cannot
  be answered at all.
  """
  @spec renew(Monitoring.EdgeDeliveryGrantRequest.t(), map()) ::
          {:ok, Monitoring.EdgeDeliveryGrantResponse.t()} | {:error, atom(), String.t()}
  def renew(%Monitoring.EdgeDeliveryGrantRequest{} = request, identity) do
    with :ok <- bounded(request),
         {:ok, snapshot} <- trust_snapshot(),
         identity = EdgeRecordTrust.with_network_scopes(snapshot, identity),
         verified = Enum.map(request.records, &verify(&1, request.spool_id, identity, snapshot)),
         {:ok, issued} <- issue(identity.component_id, verified) do
      {:ok, %Monitoring.EdgeDeliveryGrantResponse{results: Enum.map(verified, &result(&1, issued))}}
    end
  end

  defp bounded(%{spool_id: spool_id, records: records}) do
    cond do
      not uuidv7?(spool_id) ->
        {:error, :invalid_argument, "spool_id must be a UUIDv7"}

      records == [] ->
        {:error, :invalid_argument, "records is empty"}

      length(records) > @max_records ->
        {:error, :invalid_argument, "at most #{@max_records} records per request"}

      Enum.reduce(records, 0, &(byte_size(&1.record_bytes) + &2)) > @max_record_bytes ->
        {:error, :invalid_argument, "at most #{@max_record_bytes} record bytes per request"}

      not Enum.all?(records, &(is_integer(&1.sequence) and &1.sequence >= 1)) ->
        {:error, :invalid_argument, "sequence must be a positive integer"}

      length(Enum.uniq_by(records, & &1.sequence)) != length(records) ->
        {:error, :invalid_argument, "each sequence may appear once"}

      true ->
        :ok
    end
  end

  defp trust_snapshot do
    case EdgeRecordTrust.snapshot() do
      {:ok, snapshot} -> {:ok, snapshot}
      {:error, _reason} -> {:error, :unavailable, "edge record trust is not installed"}
    end
  end

  defp verify(%{sequence: sequence, record_bytes: bytes}, spool_id, identity, snapshot) do
    case EdgeRecordAuthorization.grant_subject(bytes, identity, snapshot) do
      {:ok, record} ->
        context = record.producer_context

        {:item,
         %{
           sequence: sequence,
           spool_id: spool_id,
           event_id: record.event_id,
           record_sha256: :crypto.hash(:sha256, bytes),
           network_scope_id: record.network_scope_id,
           producer_assignment_id: context.producer_assignment_id,
           run_shard: context.run_shard
         }}

      {:error, _class, reason, _event_id} ->
        {:refused, sequence, refusal(reason)}
    end
  end

  defp issue(agent_id, verified) do
    case for({:item, item} <- verified, do: item) do
      [] ->
        {:ok, %{}}

      items ->
        case core_issue(agent_id, items) do
          {:ok, results} ->
            {:ok, Map.new(results, &{&1.sequence, &1})}

          {:error, reason} ->
            Logger.warning("Edge delivery grants unavailable from core: #{inspect(reason)}")
            {:error, :unavailable, "edge delivery grants are unavailable"}
        end
    end
  end

  # Injectable as a 2-arity fun under `:edge_delivery_grant_rpc`, so tests need no core node.
  defp core_issue(agent_id, items) do
    case Application.get_env(:serviceradar_agent_gateway, :edge_delivery_grant_rpc) do
      nil -> rpc_core(agent_id, items)
      rpc -> rpc.(agent_id, items)
    end
  end

  defp rpc_core(agent_id, items) do
    core = CoreNodeForwarder.select_core_node("edge delivery grants")

    case :rpc.call(core, DeliveryGrants, :issue, [agent_id, items], @rpc_timeout_ms) do
      {:badrpc, reason} -> {:error, reason}
      result -> result
    end
  rescue
    ArgumentError -> {:error, :core_unavailable}
  end

  defp result({:refused, sequence, reason}, _issued),
    do: %Monitoring.EdgeDeliveryGrantResult{sequence: sequence, refusal: reason}

  defp result({:item, %{sequence: sequence}}, issued) do
    case Map.fetch(issued, sequence) do
      {:ok, %{delivery_capability: capability}} when not is_nil(capability) ->
        %Monitoring.EdgeDeliveryGrantResult{sequence: sequence, delivery_capability: capability}

      {:ok, %{refusal: reason}} ->
        %Monitoring.EdgeDeliveryGrantResult{sequence: sequence, refusal: refusal(reason)}

      :error ->
        %Monitoring.EdgeDeliveryGrantResult{sequence: sequence, refusal: "not_issued"}
    end
  end

  # A stable, bounded code: `production.signature` for `{:production, :signature}`.
  defp refusal(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp refusal(reason) when is_tuple(reason), do: reason |> Tuple.to_list() |> Enum.map_join(".", &refusal/1)
  defp refusal(_reason), do: "refused"

  defp uuidv7?(<<_::48, 7::4, _::12, 2::2, _::62>>), do: true
  defp uuidv7?(_spool_id), do: false
end
