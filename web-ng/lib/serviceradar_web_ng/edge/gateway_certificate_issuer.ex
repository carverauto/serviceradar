defmodule ServiceRadarWebNG.Edge.GatewayCertificateIssuer do
  @moduledoc """
  Issues agent mTLS bundles by calling the agent-gateway over ERTS RPC.
  """

  require Logger

  alias ServiceRadar.GatewayRegistry

  @default_timeout 30_000

  @spec issue_agent_bundle(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, atom()}
  def issue_agent_bundle(gateway_id, component_id, partition_id, opts \\ [])

  def issue_agent_bundle(gateway_id, component_id, partition_id, opts)
      when is_binary(gateway_id) and is_binary(component_id) and is_binary(partition_id) do
    with {:ok, node} <- lookup_gateway_node(gateway_id),
         {:ok, bundle} <- rpc_issue(node, component_id, partition_id, opts) do
      {:ok, bundle}
    end
  end

  def issue_agent_bundle(_, _, _, _), do: {:error, :invalid_identity}

  defp lookup_gateway_node(gateway_id) do
    case GatewayRegistry.lookup(gateway_id) do
      [{_pid, metadata} | _] ->
        case metadata[:node] do
          node when is_atom(node) -> {:ok, node}
          _ -> {:error, :gateway_unavailable}
        end

      _ ->
        {:error, :gateway_unavailable}
    end
  end

  defp rpc_issue(node, component_id, partition_id, opts) do
    timeout = Keyword.get(opts, :timeout_ms, @default_timeout)
    validity_days = Keyword.get(opts, :validity_days)

    rpc_opts =
      []
      |> maybe_put(:validity_days, validity_days)

    case :rpc.call(
           node,
           ServiceRadarAgentGateway.CertIssuer,
           :issue_agent_bundle,
           [component_id, partition_id, :agent, rpc_opts],
           timeout
         ) do
      {:ok, bundle} ->
        {:ok, bundle}

      {:error, reason} ->
        Logger.warning("[GatewayCertificateIssuer] Issue bundle failed: #{inspect(reason)}")
        {:error, reason}

      {:badrpc, reason} ->
        Logger.warning("[GatewayCertificateIssuer] Gateway RPC failed: #{inspect(reason)}")
        {:error, :gateway_unavailable}
    end
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
