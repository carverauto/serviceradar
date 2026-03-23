defmodule ServiceRadarAgentGateway.TestSupport.CameraMediaForwarderProxy do
  @moduledoc false

  alias ServiceRadarAgentGateway.CameraMediaForwarder

  def open_relay_session(request) do
    CameraMediaForwarder.open_relay_session(request, forwarder_opts())
  end

  def upload_media(request_stream) do
    CameraMediaForwarder.upload_media(request_stream, forwarder_opts())
  end

  def heartbeat(request) do
    CameraMediaForwarder.heartbeat(request, forwarder_opts())
  end

  def close_relay_session(request) do
    CameraMediaForwarder.close_relay_session(request, forwarder_opts())
  end

  defp forwarder_opts do
    [
      host: Application.get_env(:serviceradar_agent_gateway, :camera_media_test_forwarder_host, "127.0.0.1"),
      port: Application.get_env(:serviceradar_agent_gateway, :camera_media_test_forwarder_port, 50_062),
      ssl: false
    ]
  end
end
