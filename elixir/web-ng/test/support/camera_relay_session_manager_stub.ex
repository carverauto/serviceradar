defmodule ServiceRadarWebNG.TestSupport.CameraRelaySessionManagerStub do
  @moduledoc false

  def request_open(camera_source_id, stream_profile_id, opts) do
    notify({:open_session, camera_source_id, stream_profile_id, opts})

    Application.get_env(
      :serviceradar_web_ng,
      :camera_relay_session_manager_open_result,
      {:error, :not_configured}
    )
  end

  def open_session(camera_source_id, stream_profile_id, opts) do
    request_open(camera_source_id, stream_profile_id, opts)
  end

  def request_close(relay_session_id, opts) do
    notify({:close_session, relay_session_id, opts})

    Application.get_env(
      :serviceradar_web_ng,
      :camera_relay_session_manager_close_result,
      {:error, :not_configured}
    )
  end

  def close_session(relay_session_id, opts) do
    request_close(relay_session_id, opts)
  end

  defp notify(message) do
    case Application.get_env(:serviceradar_web_ng, :camera_relay_session_manager_test_pid) do
      pid when is_pid(pid) -> send(pid, message)
      _other -> :ok
    end
  end
end
