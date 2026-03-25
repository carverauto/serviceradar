defmodule ServiceRadarWebNG.TestSupport.CameraRelayWebRTCSignalingManagerStub do
  @moduledoc false

  def create_session(relay_session_id, opts) do
    notify({:webrtc_create_session, relay_session_id, opts})

    resolve_result(
      Application.get_env(
        :serviceradar_web_ng,
        :camera_relay_webrtc_create_result,
        {:error, :not_configured}
      ),
      relay_session_id,
      opts
    )
  end

  def submit_answer(relay_session_id, viewer_session_id, answer_sdp, opts) do
    notify({:webrtc_submit_answer, relay_session_id, viewer_session_id, answer_sdp, opts})

    resolve_result(
      Application.get_env(
        :serviceradar_web_ng,
        :camera_relay_webrtc_answer_result,
        {:error, :not_configured}
      ),
      relay_session_id,
      viewer_session_id,
      answer_sdp,
      opts
    )
  end

  def add_ice_candidate(relay_session_id, viewer_session_id, candidate, opts) do
    notify({:webrtc_add_candidate, relay_session_id, viewer_session_id, candidate, opts})

    resolve_result(
      Application.get_env(
        :serviceradar_web_ng,
        :camera_relay_webrtc_candidate_result,
        {:error, :not_configured}
      ),
      relay_session_id,
      viewer_session_id,
      candidate,
      opts
    )
  end

  def close_session(relay_session_id, viewer_session_id, opts) do
    notify({:webrtc_close_session, relay_session_id, viewer_session_id, opts})

    resolve_result(
      Application.get_env(
        :serviceradar_web_ng,
        :camera_relay_webrtc_close_result,
        {:error, :not_configured}
      ),
      relay_session_id,
      viewer_session_id,
      opts
    )
  end

  defp resolve_result(result, arg1, opts) when is_function(result, 2), do: result.(arg1, opts)
  defp resolve_result(result, _arg1, _opts), do: result

  defp resolve_result(result, arg1, arg2, arg3, opts) when is_function(result, 4), do: result.(arg1, arg2, arg3, opts)

  defp resolve_result(result, _arg1, _arg2, _arg3, _opts), do: result

  defp resolve_result(result, arg1, arg2, opts) when is_function(result, 3), do: result.(arg1, arg2, opts)

  defp resolve_result(result, _arg1, _arg2, _opts), do: result

  defp notify(message) do
    case Application.get_env(:serviceradar_web_ng, :camera_relay_webrtc_test_pid) do
      pid when is_pid(pid) -> send(pid, message)
      _other -> :ok
    end
  end
end
