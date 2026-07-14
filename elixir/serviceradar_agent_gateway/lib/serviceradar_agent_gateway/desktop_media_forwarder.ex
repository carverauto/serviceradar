defmodule ServiceRadarAgentGateway.DesktopMediaForwarder do
  @moduledoc """
  Forwards gateway-accepted desktop media frames to the core-elx ingress.

  The gateway keeps the edge-facing mTLS, route, and session checks. Core-elx
  owns the viewer/media ingress boundary that browser delivery attaches to.
  """

  alias ServiceRadarAgentGateway.CoreNodeForwarder
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

  def close_session(desktop_session_id, opts \\ []) when is_binary(desktop_session_id) do
    with {:ok, core_node} <- resolve_core_node(opts),
         :ok <- ensure_core_connected(core_node, opts) do
      do_close_session(
        desktop_session_id,
        Keyword.put(opts, :core_node, core_node),
        retry_attempts(opts)
      )
    end
  end

  defp do_forward_frame(frame, session, opts, remaining_attempts) do
    case rpc_module(opts).call(
           core_node(opts),
           ingress_module(opts),
           :forward_frame,
           [frame, session],
           timeout(opts)
         ) do
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

  defp do_close_session(desktop_session_id, opts, remaining_attempts) do
    case rpc_module(opts).call(
           core_node(opts),
           ingress_module(opts),
           :close_session,
           [desktop_session_id],
           timeout(opts)
         ) do
      {:badrpc, :nodedown} when remaining_attempts > 0 ->
        Logger.warning(
          "Desktop media close hit :nodedown talking to core-elx; retrying (remaining=#{remaining_attempts})"
        )

        _ = ensure_core_connected(core_node(opts), opts)
        do_close_session(desktop_session_id, opts, remaining_attempts - 1)

      {:badrpc, reason} ->
        Logger.error("Failed to close desktop media ingress on core-elx: #{inspect(reason)}")
        {:error, :core_unavailable}

      :ok ->
        :ok

      {:error, _reason} = error ->
        error

      other ->
        {:error, {:unexpected_close_response, other}}
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
        CoreNodeForwarder.select_core_node("desktop media ingress")

      other ->
        raise ArgumentError, "invalid core node for desktop media forwarder: #{inspect(other)}"
    end
  end

  defp resolve_core_node(opts) do
    CoreNodeForwarder.resolve_core_node("desktop media forwarder", core_node_resolver(opts))
  end

  defp ensure_core_connected(node, opts) when is_atom(node) do
    CoreNodeForwarder.ensure_core_connected(node, connectivity_module(opts))
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
