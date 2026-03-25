defmodule ServiceRadarAgentGateway.TestSupport.CameraMediaForwarderProxy do
  @moduledoc false

  alias ServiceRadarAgentGateway.CameraMediaForwarder

  def open_relay_session(request, opts \\ []) do
    CameraMediaForwarder.open_relay_session(request, Keyword.merge(forwarder_opts(), opts))
  end

  def upload_media(request_stream, opts \\ []) do
    CameraMediaForwarder.upload_media(request_stream, Keyword.merge(forwarder_opts(), opts))
  end

  def heartbeat(request, opts \\ []) do
    CameraMediaForwarder.heartbeat(request, Keyword.merge(forwarder_opts(), opts))
  end

  def close_relay_session(request, opts \\ []) do
    CameraMediaForwarder.close_relay_session(request, Keyword.merge(forwarder_opts(), opts))
  end

  defp forwarder_opts do
    Enum.reject(
      [
        core_node: Application.get_env(:serviceradar_agent_gateway, :camera_media_test_forwarder_core_node, node()),
        ingress_module:
          Application.get_env(
            :serviceradar_agent_gateway,
            :camera_media_test_forwarder_ingress_module
          )
      ],
      fn {_key, value} -> is_nil(value) end
    )
  end
end
