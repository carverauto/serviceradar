defmodule ServiceRadarWebNG.TestSupport.RemoteDesktopWebRTCSignalingManagerStub do
  @moduledoc false

  def create_session(session_id, opts) do
    notify({:desktop_webrtc_create_session, session_id, opts})

    resolve_result(
      Application.get_env(
        :serviceradar_web_ng,
        :remote_access_desktop_webrtc_create_result,
        {:error, :not_configured}
      ),
      session_id,
      opts
    )
  end

  def submit_answer(session_id, viewer_session_id, answer_sdp, opts) do
    notify({:desktop_webrtc_submit_answer, session_id, viewer_session_id, answer_sdp, opts})

    resolve_result(
      Application.get_env(
        :serviceradar_web_ng,
        :remote_access_desktop_webrtc_answer_result,
        {:error, :not_configured}
      ),
      session_id,
      viewer_session_id,
      answer_sdp,
      opts
    )
  end

  def add_ice_candidate(session_id, viewer_session_id, candidate, opts) do
    notify({:desktop_webrtc_add_candidate, session_id, viewer_session_id, candidate, opts})

    resolve_result(
      Application.get_env(
        :serviceradar_web_ng,
        :remote_access_desktop_webrtc_candidate_result,
        {:error, :not_configured}
      ),
      session_id,
      viewer_session_id,
      candidate,
      opts
    )
  end

  def close_session(session_id, viewer_session_id, opts) do
    notify({:desktop_webrtc_close_session, session_id, viewer_session_id, opts})

    resolve_result(
      Application.get_env(
        :serviceradar_web_ng,
        :remote_access_desktop_webrtc_close_result,
        {:error, :not_configured}
      ),
      session_id,
      viewer_session_id,
      opts
    )
  end

  def close_all_for_session(session_id, opts) do
    notify({:desktop_webrtc_close_all_for_session, session_id, opts})

    resolve_result(
      Application.get_env(
        :serviceradar_web_ng,
        :remote_access_desktop_webrtc_close_all_result,
        {:ok, %{closed_viewer_count: 0}}
      ),
      session_id,
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
    case Application.get_env(:serviceradar_web_ng, :remote_access_desktop_webrtc_test_pid) do
      pid when is_pid(pid) -> send(pid, message)
      _other -> :ok
    end
  end
end
