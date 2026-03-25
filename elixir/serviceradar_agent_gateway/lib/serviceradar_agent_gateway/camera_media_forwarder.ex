defmodule ServiceRadarAgentGateway.CameraMediaForwarder do
  @moduledoc """
  Forwards gateway-accepted camera media sessions to the core-elx ERTS ingress.

  The gateway remains the edge-facing trust boundary. Core-elx becomes the
  authoritative ingress for relay session ownership and media pipeline startup.
  """

  alias ServiceRadarCoreElx.CameraMediaIngress

  require Logger

  @default_timeout 15_000

  def open_relay_session(%Camera.OpenRelaySessionRequest{} = request, opts \\ []) do
    case :rpc.call(core_node(opts), ingress_module(opts), :open_relay_session, [request], timeout(opts)) do
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

  defp core_node(opts) do
    case opts[:core_node] || Application.get_env(:serviceradar_agent_gateway, :camera_media_forwarder_core_node) do
      node when is_atom(node) ->
        node

      nil ->
        select_core_node()

      other ->
        raise ArgumentError, "invalid core node for camera media forwarder: #{inspect(other)}"
    end
  end

  defp select_core_node do
    Node.list()
    |> Enum.find(fn node ->
      case :rpc.call(node, Process, :whereis, [ServiceRadar.ClusterHealth], 5_000) do
        pid when is_pid(pid) -> true
        _ -> false
      end
    end)
    |> case do
      nil -> raise ArgumentError, "no core-elx node available for camera media ingress"
      node -> node
    end
  end

  defp ingress_module(opts) do
    opts[:ingress_module] ||
      Application.get_env(
        :serviceradar_agent_gateway,
        :camera_media_forwarder_ingress_module,
        CameraMediaIngress
      )
  end
end
