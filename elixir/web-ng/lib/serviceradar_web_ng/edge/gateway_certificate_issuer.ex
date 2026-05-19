defmodule ServiceRadarWebNG.Edge.GatewayCertificateIssuer do
  @moduledoc """
  Issues agent mTLS bundles by calling the agent-gateway over ERTS RPC.
  """

  alias ServiceRadar.GatewayRegistry
  alias ServiceRadar.GatewayTracker

  require Logger

  @default_timeout 30_000

  @spec issue_agent_bundle(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, atom()}
  def issue_agent_bundle(gateway_id, component_id, partition_id, opts \\ [])

  def issue_agent_bundle(gateway_id, component_id, partition_id, opts)
      when is_binary(gateway_id) and is_binary(component_id) and is_binary(partition_id) do
    with {:ok, node} <- lookup_gateway_node(gateway_id),
         {:ok, _bundle} = ok <- rpc_issue(node, component_id, partition_id, opts) do
      ok
    end
  end

  def issue_agent_bundle(_, _, _, _), do: {:error, :invalid_identity}

  @spec revoke_agent_certificate(String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, atom()}
  def revoke_agent_certificate(gateway_id, component_id, opts \\ [])

  def revoke_agent_certificate(gateway_id, component_id, opts) when is_binary(gateway_id) and is_binary(component_id) do
    with {:ok, node} <- lookup_gateway_node(gateway_id),
         :ok <- rpc_revoke(node, component_id, opts) do
      {:ok, %{gateway_id: gateway_id, component_id: component_id, revoked: true}}
    end
  end

  def revoke_agent_certificate(_, _, _), do: {:error, :invalid_identity}

  defp lookup_gateway_node(gateway_id) do
    case GatewayRegistry.lookup(gateway_id) do
      [{_pid, metadata} | _] ->
        case metadata[:node] do
          node when is_atom(node) -> {:ok, node}
          _ -> lookup_gateway_node_from_tracker(gateway_id)
        end

      _ ->
        lookup_gateway_node_from_tracker(gateway_id)
    end
  end

  defp lookup_gateway_node_from_tracker(gateway_id) do
    Enum.find_value([Node.self() | Node.list()], {:error, :gateway_unavailable}, fn node ->
      case :rpc.call(node, GatewayTracker, :get_gateway, [gateway_id], 1_500) do
        %{node: tracker_node} when is_atom(tracker_node) -> {:ok, tracker_node}
        _ -> false
      end
    end)
  end

  defp rpc_issue(node, component_id, partition_id, opts) do
    timeout = Keyword.get(opts, :timeout_ms, @default_timeout)
    validity_days = Keyword.get(opts, :validity_days)
    issuer_module = Keyword.get(opts, :cert_issuer_module, ServiceRadarAgentGateway.CertIssuer)

    rpc_opts = maybe_put([], :validity_days, validity_days)
    rpc_opts = maybe_put(rpc_opts, :authorized_component_id, Keyword.get(opts, :authorized_component_id))
    rpc_opts = maybe_put(rpc_opts, :authorized_partition_id, Keyword.get(opts, :authorized_partition_id))
    rpc_opts = maybe_put(rpc_opts, :audit_actor, Keyword.get(opts, :audit_actor) || Keyword.get(opts, :actor))
    rpc_opts = maybe_put(rpc_opts, :long_ttl_approved_by, Keyword.get(opts, :long_ttl_approved_by))

    case :rpc.call(
           node,
           issuer_module,
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

  defp rpc_revoke(node, component_id, opts) do
    timeout = Keyword.get(opts, :timeout_ms, @default_timeout)
    reason = Keyword.get(opts, :reason)
    revocation_module = Keyword.get(opts, :revocation_module, ServiceRadarAgentGateway.AgentCertificateRevocation)

    case :rpc.call(
           node,
           revocation_module,
           :revoke_component_id,
           [component_id, [reason: reason]],
           timeout
         ) do
      :ok ->
        :ok

      {:badrpc, reason} ->
        Logger.warning("[GatewayCertificateIssuer] Gateway revoke RPC failed: #{inspect(reason)}")
        {:error, :gateway_unavailable}

      other ->
        Logger.warning("[GatewayCertificateIssuer] Unexpected revoke result: #{inspect(other)}")
        {:error, :gateway_unavailable}
    end
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
