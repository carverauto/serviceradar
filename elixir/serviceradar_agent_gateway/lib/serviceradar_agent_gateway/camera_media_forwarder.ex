defmodule ServiceRadarAgentGateway.CameraMediaForwarder do
  @moduledoc """
  Forwards gateway-accepted camera media sessions to the core-elx ERTS ingress.

  The gateway remains the edge-facing trust boundary. Core-elx becomes the
  authoritative ingress for relay session ownership and media pipeline startup.
  """

  alias ServiceRadarCoreElx.CameraMediaIngress

  require Logger

  @default_timeout 15_000
  @default_open_retry_attempts 1

  def open_relay_session(%Camera.OpenRelaySessionRequest{} = request, opts \\ []) do
    with {:ok, core_node} <- resolve_core_node(opts),
         :ok <- ensure_core_connected(core_node, opts) do
      do_open_relay_session(request, Keyword.put(opts, :core_node, core_node), open_retry_attempts(opts))
    end
  end

  defp do_open_relay_session(%Camera.OpenRelaySessionRequest{} = request, opts, remaining_attempts) do
    case rpc_module(opts).call(core_node(opts), ingress_module(opts), :open_relay_session, [request], timeout(opts)) do
      {:badrpc, :nodedown} when remaining_attempts > 0 ->
        Logger.warning("Camera relay open hit :nodedown talking to core-elx; retrying (remaining=#{remaining_attempts})")

        _ = ensure_core_connected(core_node(opts), opts)
        do_open_relay_session(request, opts, remaining_attempts - 1)

      {:badrpc, reason} ->
        Logger.error("Failed to open camera relay session on core-elx ingress: #{inspect(reason)}")
        {:error, :core_unavailable}

      {:ok, %Camera.OpenRelaySessionResponse{} = response, metadata} ->
        {:ok, response, metadata}

      {:error, _reason} = error ->
        error

      other ->
        {:error, {:unexpected_open_response, other}}
    end
  end

  def upload_media(request_stream, opts \\ []) do
    with_ingress_pid(opts, fn ingress_pid ->
      chunks = Enum.to_list(request_stream)
      GenServer.call(ingress_pid, {:upload_media, chunks}, timeout(opts))
    end)
  end

  def heartbeat(%Camera.RelayHeartbeat{} = request, opts \\ []) do
    with_ingress_pid(opts, fn ingress_pid ->
      GenServer.call(ingress_pid, {:heartbeat, request}, timeout(opts))
    end)
  end

  def close_relay_session(%Camera.CloseRelaySessionRequest{} = request, opts \\ []) do
    with_ingress_pid(opts, fn ingress_pid ->
      GenServer.call(ingress_pid, {:close_relay_session, request}, timeout(opts))
    end)
  end

  defp with_ingress_pid(opts, fun) when is_function(fun, 1) do
    case Keyword.get(opts, :ingress_pid) do
      ingress_pid when is_pid(ingress_pid) ->
        try do
          fun.(ingress_pid)
        catch
          :exit, reason ->
            Logger.warning("ERTS camera media ingress call failed: #{inspect(reason)}")
            {:error, :core_unavailable}
        end

      other ->
        Logger.error("Camera media forwarder missing ingress pid: #{inspect(other)}")
        {:error, :missing_ingress_pid}
    end
  end

  defp timeout(opts), do: opts[:timeout] || @default_timeout

  defp open_retry_attempts(opts) do
    opts[:open_retry_attempts] ||
      Application.get_env(
        :serviceradar_agent_gateway,
        :camera_media_forwarder_open_retry_attempts,
        @default_open_retry_attempts
      )
  end

  defp core_node(opts) do
    case opts[:core_node] || Application.get_env(:serviceradar_agent_gateway, :camera_media_forwarder_core_node) do
      node when is_atom(node) and not is_nil(node) ->
        node

      nil ->
        select_core_node()

      other ->
        raise ArgumentError, "invalid core node for camera media forwarder: #{inspect(other)}"
    end
  end

  defp resolve_core_node(opts) do
    case core_node_resolver(opts).() do
      node when is_atom(node) and not is_nil(node) ->
        {:ok, node}

      other ->
        Logger.error(
          "Failed to resolve core node for camera media forwarder: #{inspect(other)} (connected=#{inspect(Node.list())})"
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
        _ -> false
      end
    end)
    |> Kernel.||(Enum.find(nodes, &core_node?/1))
    |> case do
      nil -> raise ArgumentError, "no core-elx node available for camera media ingress"
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
        :camera_media_forwarder_ingress_module,
        CameraMediaIngress
      )
  end

  defp rpc_module(opts) do
    opts[:rpc_module] ||
      Application.get_env(:serviceradar_agent_gateway, :camera_media_forwarder_rpc_module, :rpc)
  end

  defp core_node_resolver(opts) do
    opts[:core_node_resolver] || fn -> core_node(opts) end
  end

  defp connectivity_module(opts) do
    opts[:connectivity_module] ||
      Application.get_env(
        :serviceradar_agent_gateway,
        :camera_media_forwarder_connectivity_module,
        :net_adm
      )
  end
end
