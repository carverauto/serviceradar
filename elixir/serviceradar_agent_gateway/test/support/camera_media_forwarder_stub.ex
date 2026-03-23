defmodule ServiceRadarAgentGateway.TestSupport.CameraMediaForwarderStub do
  @moduledoc false

  def open_relay_session(request) do
    notify({:open_relay_session, request})

    Application.get_env(
      :serviceradar_agent_gateway,
      :camera_media_forwarder_open_result,
      {:error, :not_configured}
    )
  end

  def upload_media(request_stream) do
    chunks = Enum.to_list(request_stream)
    notify({:upload_media, chunks})

    Application.get_env(
      :serviceradar_agent_gateway,
      :camera_media_forwarder_upload_result,
      {:error, :not_configured}
    )
  end

  def heartbeat(request) do
    notify({:heartbeat, request})

    Application.get_env(
      :serviceradar_agent_gateway,
      :camera_media_forwarder_heartbeat_result,
      {:error, :not_configured}
    )
  end

  def close_relay_session(request) do
    notify({:close_relay_session, request})

    Application.get_env(
      :serviceradar_agent_gateway,
      :camera_media_forwarder_close_result,
      {:error, :not_configured}
    )
  end

  defp notify(message) do
    case Application.get_env(:serviceradar_agent_gateway, :camera_media_server_test_pid) do
      pid when is_pid(pid) -> send(pid, message)
      _other -> :ok
    end
  end
end
