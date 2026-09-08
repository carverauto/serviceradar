defmodule ServiceRadarCoreElx.TestSupport.CameraMediaSessionTrackerStub do
  @moduledoc false

  def open_session(attrs) do
    notify({:open_session, attrs})
    Application.get_env(:serviceradar_core_elx, :camera_media_server_open_result, {:error, :not_configured})
  end

  def heartbeat(relay_session_id, media_ingest_id, attrs) do
    notify({:heartbeat, relay_session_id, media_ingest_id, attrs})

    Application.get_env(
      :serviceradar_core_elx,
      :camera_media_server_heartbeat_result,
      {:error, :not_configured}
    )
  end

  def close_session(relay_session_id, media_ingest_id, attrs) do
    notify({:close_session, relay_session_id, media_ingest_id, attrs})

    Application.get_env(
      :serviceradar_core_elx,
      :camera_media_server_close_result,
      {:error, :not_configured}
    )
  end

  def record_chunk(relay_session_id, media_ingest_id, attrs) do
    notify({:record_chunk, relay_session_id, media_ingest_id, attrs})

    Application.get_env(
      :serviceradar_core_elx,
      :camera_media_server_record_chunk_result,
      {:error, :not_configured}
    )
  end

  defp notify(message) do
    case Application.get_env(:serviceradar_core_elx, :camera_media_server_test_pid) do
      pid when is_pid(pid) -> send(pid, message)
      _other -> :ok
    end
  end
end
