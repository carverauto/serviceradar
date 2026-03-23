defmodule ServiceRadarWebNG.TestSupport.CameraRelaySessionManagerStub do
  @moduledoc false

  def request_open(camera_source_id, stream_profile_id, opts) do
    notify({:open_session, camera_source_id, stream_profile_id, opts})

    resolve_result(
      Application.get_env(
        :serviceradar_web_ng,
        :camera_relay_session_manager_open_result,
        {:error, :not_configured}
      ),
      camera_source_id,
      stream_profile_id,
      opts
    )
  end

  def open_session(camera_source_id, stream_profile_id, opts) do
    request_open(camera_source_id, stream_profile_id, opts)
  end

  def request_close(relay_session_id, opts) do
    notify({:close_session, relay_session_id, opts})

    resolve_result(
      Application.get_env(
        :serviceradar_web_ng,
        :camera_relay_session_manager_close_result,
        {:error, :not_configured}
      ),
      relay_session_id,
      opts
    )
  end

  def close_session(relay_session_id, opts) do
    request_close(relay_session_id, opts)
  end

  defp resolve_result(result, arg1, arg2, opts) when is_function(result, 3), do: result.(arg1, arg2, opts)
  defp resolve_result(result, _arg1, _arg2, _opts), do: result

  defp resolve_result(result, arg1, opts) when is_function(result, 2), do: result.(arg1, opts)
  defp resolve_result(result, _arg1, _opts), do: result

  defp notify(message) do
    case Application.get_env(:serviceradar_web_ng, :camera_relay_session_manager_test_pid) do
      pid when is_pid(pid) -> send(pid, message)
      _other -> :ok
    end
  end
end
