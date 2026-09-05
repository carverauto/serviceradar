defmodule ServiceRadarAgentGateway.RemoteCaptureForwarder do
  @moduledoc """
  Opens one remote-capture ingress on core-elx, then forwards the stream directly
  to the returned process.

  Only session establishment crosses `:rpc`. Blocks and lifecycle updates use
  the ingress pid, preserving ordering and avoiding one distributed RPC per
  pcapng block.
  """

  alias ServiceRadarAgentGateway.CoreNodeForwarder
  alias ServiceRadarCoreElx.RemoteCaptureIngress

  require Logger

  @default_timeout 15_000
  @default_open_retry_attempts 1

  def open_session(%Remotecapture.StartRemoteCaptureSession{} = request, metadata, opts \\ []) when is_map(metadata) do
    with {:ok, core_node} <- resolve_core_node(opts),
         :ok <- ensure_core_connected(core_node, opts) do
      opts = Keyword.put(opts, :core_node, core_node)
      do_open_session(request, metadata, opts, open_retry_attempts(opts))
    end
  end

  def forward_block(ingress_pid, %Remotecapture.CaptureBlock{} = block, opts \\ []) do
    call_ingress(ingress_pid, {:capture_block, block}, opts)
  end

  def forward_state(ingress_pid, %Remotecapture.SessionStateChanged{} = state, opts \\ []) do
    call_ingress(ingress_pid, {:capture_state, state}, opts)
  end

  def disconnect(ingress_pid, session_id, opts \\ []) do
    call_ingress(ingress_pid, {:capture_disconnected, session_id}, opts)
  end

  defp do_open_session(request, metadata, opts, remaining_attempts) do
    result =
      rpc_module(opts).call(
        core_node(opts),
        ingress_module(opts),
        :open_session,
        [request, metadata],
        timeout(opts)
      )

    case result do
      {:badrpc, :nodedown} when remaining_attempts > 0 ->
        Logger.warning(
          "Remote capture open hit :nodedown talking to core-elx; retrying (remaining=#{remaining_attempts})"
        )

        _ = ensure_core_connected(core_node(opts), opts)
        do_open_session(request, metadata, opts, remaining_attempts - 1)

      {:badrpc, reason} ->
        Logger.error("Failed to open remote capture on core-elx ingress: #{inspect(reason)}")
        {:error, :core_unavailable}

      {:ok, ingress_pid} when is_pid(ingress_pid) ->
        {:ok, ingress_pid}

      {:ok, ingress_pid, response_metadata} when is_pid(ingress_pid) and is_map(response_metadata) ->
        {:ok, ingress_pid, response_metadata}

      {:error, _reason} = error ->
        error

      other ->
        {:error, {:unexpected_open_response, other}}
    end
  end

  defp call_ingress(ingress_pid, message, opts) when is_pid(ingress_pid) do
    GenServer.call(ingress_pid, message, timeout(opts))
  catch
    :exit, reason ->
      Logger.warning("ERTS remote capture ingress call failed: #{inspect(reason)}")
      {:error, :core_unavailable}
  end

  defp call_ingress(_ingress_pid, _message, _opts), do: {:error, :missing_ingress_pid}

  defp timeout(opts), do: opts[:timeout] || @default_timeout

  defp open_retry_attempts(opts) do
    opts[:open_retry_attempts] ||
      Application.get_env(
        :serviceradar_agent_gateway,
        :remote_capture_forwarder_open_retry_attempts,
        @default_open_retry_attempts
      )
  end

  defp core_node(opts) do
    case opts[:core_node] ||
           Application.get_env(:serviceradar_agent_gateway, :remote_capture_forwarder_core_node) do
      node when is_atom(node) and not is_nil(node) ->
        node

      nil ->
        CoreNodeForwarder.select_core_node("remote capture ingress")

      other ->
        raise ArgumentError, "invalid core node for remote capture forwarder: #{inspect(other)}"
    end
  end

  defp resolve_core_node(opts) do
    CoreNodeForwarder.resolve_core_node("remote capture forwarder", core_node_resolver(opts))
  end

  defp ensure_core_connected(node, opts) do
    CoreNodeForwarder.ensure_core_connected(node, connectivity_module(opts))
  end

  defp ingress_module(opts) do
    opts[:ingress_module] ||
      Application.get_env(
        :serviceradar_agent_gateway,
        :remote_capture_forwarder_ingress_module,
        RemoteCaptureIngress
      )
  end

  defp rpc_module(opts) do
    opts[:rpc_module] ||
      Application.get_env(:serviceradar_agent_gateway, :remote_capture_forwarder_rpc_module, :rpc)
  end

  defp core_node_resolver(opts), do: opts[:core_node_resolver] || fn -> core_node(opts) end

  defp connectivity_module(opts) do
    opts[:connectivity_module] ||
      Application.get_env(
        :serviceradar_agent_gateway,
        :remote_capture_forwarder_connectivity_module,
        :net_adm
      )
  end
end
