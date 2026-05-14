defmodule ServiceRadarAgentGateway.DesktopMediaForwarder do
  @moduledoc """
  Forwards gateway-accepted desktop media frames to the core-elx ingress.

  The gateway keeps the edge-facing mTLS, route, and session checks. Core-elx
  owns the viewer/media ingress boundary that browser delivery attaches to.
  """

  alias ServiceRadarCoreElx.DesktopMediaIngress

  require Logger

  @default_timeout 15_000
  @default_retry_attempts 1

  def forward_frame(%Desktopmedia.DesktopMediaFrameChunk{} = frame, session, opts \\ []) when is_map(session) do
    with {:ok, core_node} <- resolve_core_node(opts),
         :ok <- ensure_core_connected(core_node, opts) do
      do_forward_frame(frame, session, Keyword.put(opts, :core_node, core_node), retry_attempts(opts))
    end
  end

  defp do_forward_frame(frame, session, opts, remaining_attempts) do
    case rpc_module(opts).call(core_node(opts), ingress_module(opts), :forward_frame, [frame, session], timeout(opts)) do
      {:badrpc, :nodedown} when remaining_attempts > 0 ->
        Logger.warning(
          "Desktop media frame forward hit :nodedown talking to core-elx; retrying (remaining=#{remaining_attempts})"
        )

        _ = ensure_core_connected(core_node(opts), opts)
        do_forward_frame(frame, session, opts, remaining_attempts - 1)

      {:badrpc, reason} ->
        Logger.error("Failed to forward desktop media frame to core-elx ingress: #{inspect(reason)}")
        {:error, :core_unavailable}

      {:ok, %Desktopmedia.DesktopMediaAck{} = ack} ->
        {:ok, ack}

      {:error, _reason} = error ->
        error

      other ->
        {:error, {:unexpected_forward_response, other}}
    end
  end

  defp timeout(opts), do: opts[:timeout] || @default_timeout

  defp retry_attempts(opts) do
    opts[:retry_attempts] ||
      Application.get_env(
        :serviceradar_agent_gateway,
        :desktop_media_forwarder_retry_attempts,
        @default_retry_attempts
      )
  end

  defp core_node(opts) do
    case opts[:core_node] || Application.get_env(:serviceradar_agent_gateway, :desktop_media_forwarder_core_node) do
      node when is_atom(node) and not is_nil(node) ->
        node

      nil ->
        select_core_node()

      other ->
        raise ArgumentError, "invalid core node for desktop media forwarder: #{inspect(other)}"
    end
  end

  defp resolve_core_node(opts) do
    case core_node_resolver(opts).() do
      node when is_atom(node) and not is_nil(node) ->
        {:ok, node}

      other ->
        Logger.error(
          "Failed to resolve core node for desktop media forwarder: #{inspect(other)} (connected=#{inspect(Node.list())})"
        )

        {:error, :core_unavailable}
    end
  end

  defp ensure_core_connected(node, opts) when is_atom(node) do
    case connectivity_module(opts).ping(node) do
      :pong ->
        :ok

      :pang ->
        Logger.error("Failed to establish distributed Erlang connection to core node #{inspect(node)}")
        {:error, :core_unavailable}

      other ->
        Logger.error("Unexpected core connectivity probe result for #{inspect(node)}: #{inspect(other)}")
        {:error, :core_unavailable}
    end
  end

  defp ensure_core_connected(node, _opts) do
    Logger.error("Failed to establish distributed Erlang connection to core node #{inspect(node)}")
    {:error, :core_unavailable}
  end

  defp select_core_node do
    nodes = Node.list()

    nodes
    |> Enum.find(fn node ->
      case :rpc.call(node, Process, :whereis, [ServiceRadar.ClusterHealth], 5_000) do
        pid when is_pid(pid) -> true
        _other -> false
      end
    end)
    |> Kernel.||(Enum.find(nodes, &core_node?/1))
    |> case do
      nil -> raise ArgumentError, "no core-elx node available for desktop media ingress"
      node -> node
    end
  end

  defp core_node?(node) when is_atom(node) do
    String.starts_with?(Atom.to_string(node), "#{core_node_basename()}@")
  end

  defp core_node?(_node), do: false

  defp core_node_basename do
    System.get_env("CLUSTER_CORE_NODE_BASENAME") ||
      Application.get_env(:serviceradar_agent_gateway, :cluster_core_node_basename, "serviceradar_core")
  end

  defp ingress_module(opts) do
    opts[:ingress_module] ||
      Application.get_env(
        :serviceradar_agent_gateway,
        :desktop_media_forwarder_ingress_module,
        DesktopMediaIngress
      )
  end

  defp rpc_module(opts) do
    opts[:rpc_module] ||
      Application.get_env(:serviceradar_agent_gateway, :desktop_media_forwarder_rpc_module, :rpc)
  end

  defp core_node_resolver(opts) do
    opts[:core_node_resolver] || fn -> core_node(opts) end
  end

  defp connectivity_module(opts) do
    opts[:connectivity_module] ||
      Application.get_env(
        :serviceradar_agent_gateway,
        :desktop_media_forwarder_connectivity_module,
        :net_adm
      )
  end
end
