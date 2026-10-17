defmodule ServiceRadarWebNG.CameraRelayWebRTCSignalingManager do
  @moduledoc """
  ERTS client for relay-scoped WebRTC signaling owned by `core-elx`.

  A relay's media pipeline and its viewer sessions live on the one core-elx node
  that ingests that relay, and every other node answers "not found". That node
  advertises the relay through `ServiceRadar.Camera.RelayHosts`, so each call goes
  straight to it. If that call does not get an answer, it fails as unavailable
  and is not sent again. Only when no node advertises the relay (the moment
  before its advertisement propagates, or a core-elx that predates it) does a
  call try the core-elx nodes in turn, returning the first answer that is not
  "not hosted here". When every node says so, the relay or viewer session is
  really gone. A node that does not answer has not said so, and that call stays
  unavailable.
  """

  alias ServiceRadar.Camera.RelayHosts

  @default_rpc_timeout 5_000
  @not_hosted [:not_found, :viewer_session_not_found]

  def create_session(relay_session_id, opts) when is_binary(relay_session_id) do
    rpc(:create_session, [relay_session_id, opts], opts)
  end

  def submit_answer(relay_session_id, viewer_session_id, answer_sdp, opts)
      when is_binary(relay_session_id) and is_binary(viewer_session_id) and is_binary(answer_sdp) do
    rpc(:submit_answer, [relay_session_id, viewer_session_id, answer_sdp, opts], opts)
  end

  def add_ice_candidate(relay_session_id, viewer_session_id, candidate, opts)
      when is_binary(relay_session_id) and is_binary(viewer_session_id) do
    rpc(:add_ice_candidate, [relay_session_id, viewer_session_id, candidate, opts], opts)
  end

  def get_session(relay_session_id, viewer_session_id, opts)
      when is_binary(relay_session_id) and is_binary(viewer_session_id) do
    rpc(:get_session, [relay_session_id, viewer_session_id, opts], opts)
  end

  def close_session(relay_session_id, viewer_session_id, opts)
      when is_binary(relay_session_id) and is_binary(viewer_session_id) do
    rpc(:close_session, [relay_session_id, viewer_session_id, opts], opts)
  end

  defp rpc(function, [relay_session_id | _] = args, opts) do
    module = remote_manager_module()
    timeout = Keyword.get(opts, :rpc_timeout, @default_rpc_timeout)

    case RelayHosts.host_node(relay_session_id) do
      nil ->
        scan_for_relay_host(module, function, args, timeout)

      host ->
        case :rpc.call(host, module, function, args, timeout) do
          {:badrpc, reason} -> unavailable(reason)
          result -> result
        end
    end
  end

  defp scan_for_relay_host(module, function, args, timeout) do
    case core_elx_nodes(module, timeout) do
      [] -> {:error, "camera relay webrtc signaling unavailable"}
      nodes -> call_relay_host(nodes, module, function, args, timeout, nil)
    end
  end

  defp call_relay_host([], _module, _function, _args, _timeout, last_result), do: last_result

  defp call_relay_host([node | rest], module, function, args, timeout, last_result) do
    case :rpc.call(node, module, function, args, timeout) do
      {:badrpc, reason} ->
        call_relay_host(rest, module, function, args, timeout, unavailable(reason))

      {:error, reason} = not_hosted when reason in @not_hosted ->
        call_relay_host(rest, module, function, args, timeout, keep_absent(last_result, not_hosted))

      result ->
        result
    end
  end

  defp keep_absent(nil, not_hosted), do: not_hosted

  defp keep_absent({:error, reason}, not_hosted) when reason in @not_hosted, do: not_hosted

  defp keep_absent(kept, _not_hosted), do: kept

  defp unavailable(reason) do
    {:error, "camera relay webrtc signaling unavailable: #{inspect(reason)}"}
  end

  defp core_elx_nodes(module, timeout) do
    Enum.filter(rpc_nodes(), fn node ->
      case :rpc.call(node, Process, :whereis, [module], timeout) do
        pid when is_pid(pid) -> true
        _other -> false
      end
    end)
  end

  defp remote_manager_module do
    Application.get_env(
      :serviceradar_web_ng,
      :camera_relay_webrtc_remote_manager,
      Module.concat([ServiceRadarCoreElx, CameraRelay, WebRTCSignalingManager])
    )
  end

  defp rpc_nodes do
    Application.get_env(:serviceradar_web_ng, :camera_relay_webrtc_rpc_nodes, [Node.self() | Node.list()])
  end
end
