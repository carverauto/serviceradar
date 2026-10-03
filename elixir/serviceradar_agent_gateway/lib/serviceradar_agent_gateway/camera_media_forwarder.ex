defmodule ServiceRadarAgentGateway.CameraMediaForwarder do
  @moduledoc """
  Forwards gateway-accepted camera media sessions to the core-elx ERTS ingress.

  The gateway remains the edge-facing trust boundary. Core-elx becomes the
  authoritative ingress for relay session ownership and media pipeline startup.

  Uploads use the session's core ERTS pid, not a pooled gateway-to-core gRPC
  channel. A normal ingress exit during close, or a stale pid after close, means
  the relay session ended; it does not establish a core connectivity outage.
  Open a new authorized relay session to obtain a new ingress pid. Timeouts
  report deadline_exceeded so operators can check core load, while node loss
  reports unavailable and identifies the target node in the gateway log.

  Do not retry an upload automatically: a timed-out batch may already have been
  accepted. To verify recovery, compare the core session tracker's sent_bytes,
  last_sequence and updated_at_unix across successive uploads. Gateway receipt
  counters alone are insufficient because they advance before core forwarding.
  """

  alias ServiceRadarAgentGateway.CoreNodeForwarder
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
    with_ingress_pid(opts, :upload_media, fn ingress_pid ->
      chunks = Enum.to_list(request_stream)
      GenServer.call(ingress_pid, {:upload_media, chunks}, timeout(opts))
    end)
  end

  def heartbeat(%Camera.RelayHeartbeat{} = request, opts \\ []) do
    with_ingress_pid(opts, :heartbeat, fn ingress_pid ->
      GenServer.call(ingress_pid, {:heartbeat, request}, timeout(opts))
    end)
  end

  def close_relay_session(%Camera.CloseRelaySessionRequest{} = request, opts \\ []) do
    with_ingress_pid(opts, :close_relay_session, fn ingress_pid ->
      GenServer.call(ingress_pid, {:close_relay_session, request}, timeout(opts))
    end)
  end

  defp with_ingress_pid(opts, operation, fun) when is_function(fun, 1) do
    case Keyword.get(opts, :ingress_pid) do
      ingress_pid when is_pid(ingress_pid) ->
        try do
          fun.(ingress_pid)
        catch
          :exit, {reason, {GenServer, :call, _args}} ->
            ingress_call_error(reason, ingress_pid, operation)
        end

      other ->
        Logger.error("Camera media forwarder missing ingress pid: #{inspect(other)}")
        {:error, :missing_ingress_pid}
    end
  end

  # GenServer exit terms contain the request, including private media bytes.
  # Classify the failure without logging or returning those call arguments.
  defp ingress_call_error(reason, ingress_pid, operation) do
    {status, failure, message} =
      case reason do
        closed when closed in [:normal, :noproc, :shutdown] ->
          {:not_found, :session_closed, "camera relay ingress closed; open a new relay session"}

        :timeout ->
          {:deadline_exceeded, :timeout,
           "camera relay ingress timed out; check core load before opening a new relay session"}

        {:nodedown, _node} ->
          {:unavailable, :nodedown, "camera relay core connection lost; reconnect and open a new relay session"}

        _other ->
          {:unavailable, :ingress_failed, "camera relay ingress failed; check core health and open a new relay session"}
      end

    log_level = if failure == :session_closed, do: :debug, else: :warning

    Logger.log(
      log_level,
      "ERTS camera media ingress call failed: core_node=#{node(ingress_pid)} operation=#{operation} failure=#{failure}"
    )

    {:error, GRPC.RPCError.exception(status: status, message: message)}
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
        CoreNodeForwarder.select_core_node("camera media ingress")

      other ->
        raise ArgumentError, "invalid core node for camera media forwarder: #{inspect(other)}"
    end
  end

  defp resolve_core_node(opts) do
    CoreNodeForwarder.resolve_core_node("camera media forwarder", core_node_resolver(opts))
  end

  defp ensure_core_connected(node, opts) when is_atom(node) do
    CoreNodeForwarder.ensure_core_connected(node, connectivity_module(opts))
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
