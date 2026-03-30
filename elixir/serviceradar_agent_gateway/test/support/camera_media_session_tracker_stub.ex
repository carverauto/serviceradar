defmodule ServiceRadarAgentGateway.TestSupport.CameraMediaSessionTrackerStub do
  @moduledoc false

  def open_session(attrs) do
    notify({:open_session, attrs})

    Application.get_env(
      :serviceradar_agent_gateway,
      :camera_media_session_tracker_open_result,
      {:error, :not_configured}
    )
  end

  def heartbeat(relay_session_id, media_ingest_id, attrs) do
    notify({:heartbeat_tracker, relay_session_id, media_ingest_id, attrs})

    Application.get_env(
      :serviceradar_agent_gateway,
      :camera_media_session_tracker_heartbeat_result,
      {:error, :not_configured}
    )
  end

  def heartbeat(relay_session_id, media_ingest_id, agent_id, attrs) do
    notify({:heartbeat_tracker_owned, relay_session_id, media_ingest_id, agent_id, attrs})
    heartbeat(relay_session_id, media_ingest_id, attrs)
  end

  def record_chunk(relay_session_id, media_ingest_id, attrs) do
    notify({:record_chunk, relay_session_id, media_ingest_id, attrs})

    Application.get_env(
      :serviceradar_agent_gateway,
      :camera_media_session_tracker_record_result,
      {:error, :not_configured}
    )
  end

  def record_chunk(relay_session_id, media_ingest_id, agent_id, attrs) do
    notify({:record_chunk_owned, relay_session_id, media_ingest_id, agent_id, attrs})
    record_chunk(relay_session_id, media_ingest_id, attrs)
  end

  def mark_closing(relay_session_id, media_ingest_id, attrs) do
    notify({:mark_closing, relay_session_id, media_ingest_id, attrs})

    Application.get_env(
      :serviceradar_agent_gateway,
      :camera_media_session_tracker_mark_closing_result,
      {:error, :not_configured}
    )
  end

  def mark_closing(relay_session_id, media_ingest_id, agent_id, attrs) do
    notify({:mark_closing_owned, relay_session_id, media_ingest_id, agent_id, attrs})
    mark_closing(relay_session_id, media_ingest_id, attrs)
  end

  def close_session(relay_session_id, media_ingest_id, attrs) do
    notify({:close_session, relay_session_id, media_ingest_id, attrs})

    Application.get_env(
      :serviceradar_agent_gateway,
      :camera_media_session_tracker_close_result,
      {:error, :not_configured}
    )
  end

  def close_session(relay_session_id, media_ingest_id, agent_id, attrs) do
    notify({:close_session_owned, relay_session_id, media_ingest_id, agent_id, attrs})
    close_session(relay_session_id, media_ingest_id, attrs)
  end

  def fetch_session(relay_session_id) do
    notify({:fetch_session, relay_session_id})
    Application.get_env(:serviceradar_agent_gateway, :camera_media_session_tracker_fetch_result)
  end

  def fetch_session(relay_session_id, agent_id) do
    notify({:fetch_session_owned, relay_session_id, agent_id})

    case Application.get_env(:serviceradar_agent_gateway, :camera_media_session_tracker_fetch_result) do
      {:ok, %{agent_id: ^agent_id} = session} -> {:ok, session}
      {:ok, _session} -> {:error, :agent_id_mismatch}
      %{agent_id: ^agent_id} = session -> {:ok, session}
      %{} -> {:error, :agent_id_mismatch}
      nil -> {:error, :not_found}
      {:error, _reason} = error -> error
      other -> other
    end
  end

  defp notify(message) do
    case Application.get_env(:serviceradar_agent_gateway, :camera_media_server_test_pid) do
      pid when is_pid(pid) -> send(pid, message)
      _other -> :ok
    end
  end
end
