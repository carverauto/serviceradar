defmodule ServiceRadarWebNG.CameraRelayWebRTCSignalingManager do
  @moduledoc """
  ERTS client for relay-scoped WebRTC signaling owned by `core-elx`.
  """

  @default_rpc_timeout 5_000

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

  def close_session(relay_session_id, viewer_session_id, opts)
      when is_binary(relay_session_id) and is_binary(viewer_session_id) do
    rpc(:close_session, [relay_session_id, viewer_session_id, opts], opts)
  end

  defp rpc(function, args, opts) do
    module = remote_manager_module()
    timeout = Keyword.get(opts, :rpc_timeout, @default_rpc_timeout)

    case core_elx_node(module, timeout) do
      nil ->
        {:error, "camera relay webrtc signaling unavailable"}

      node ->
        case :rpc.call(node, module, function, args, timeout) do
          {:badrpc, reason} -> {:error, "camera relay webrtc signaling unavailable: #{inspect(reason)}"}
          result -> result
        end
    end
  end

  defp core_elx_node(module, timeout) do
    Enum.find(rpc_nodes(), fn node ->
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
