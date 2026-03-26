defmodule ServiceRadarAgentGateway.TestSupport.CameraMediaCoreTestServer do
  @moduledoc false

  use GRPC.Server, service: Camera.CameraMediaService.Service

  @max_chunk_bytes 1_048_576

  def open_relay_session(%Camera.OpenRelaySessionRequest{} = request, _stream) do
    notify({:core_open_relay_session, request})

    %Camera.OpenRelaySessionResponse{
      accepted: true,
      message: "core relay session accepted",
      media_ingest_id: media_ingest_id(),
      max_chunk_bytes: @max_chunk_bytes,
      lease_expires_at_unix: lease_expires_at_unix()
    }
  end

  def upload_media(request_stream, _stream) do
    chunks = Enum.to_list(request_stream)
    notify({:core_upload_media, chunks})

    last_sequence =
      case List.last(chunks) do
        %Camera.MediaChunk{sequence: sequence} -> sequence
        _other -> 0
      end

    %Camera.UploadMediaResponse{
      received: true,
      last_sequence: last_sequence,
      message: upload_message()
    }
  end

  def heartbeat(%Camera.RelayHeartbeat{} = request, _stream) do
    notify({:core_heartbeat, request})

    %Camera.RelayHeartbeatAck{
      accepted: true,
      lease_expires_at_unix: heartbeat_lease_expires_at_unix(),
      message: heartbeat_message()
    }
  end

  def close_relay_session(%Camera.CloseRelaySessionRequest{} = request, _stream) do
    notify({:core_close_relay_session, request})

    %Camera.CloseRelaySessionResponse{
      closed: true,
      message: close_message()
    }
  end

  defp media_ingest_id do
    Application.get_env(
      :serviceradar_agent_gateway,
      :camera_media_core_test_media_ingest_id,
      "core-media-negotiation-1"
    )
  end

  defp lease_expires_at_unix do
    Application.get_env(
      :serviceradar_agent_gateway,
      :camera_media_core_test_lease_expires_at_unix,
      System.os_time(:second) + 60
    )
  end

  defp heartbeat_lease_expires_at_unix do
    Application.get_env(
      :serviceradar_agent_gateway,
      :camera_media_core_test_heartbeat_lease_expires_at_unix,
      lease_expires_at_unix()
    )
  end

  defp upload_message do
    Application.get_env(
      :serviceradar_agent_gateway,
      :camera_media_core_test_upload_message,
      "media chunks accepted by core-elx"
    )
  end

  defp heartbeat_message do
    Application.get_env(
      :serviceradar_agent_gateway,
      :camera_media_core_test_heartbeat_message,
      "core heartbeat accepted"
    )
  end

  defp close_message do
    Application.get_env(
      :serviceradar_agent_gateway,
      :camera_media_core_test_close_message,
      "core relay session closed"
    )
  end

  defp notify(message) do
    case Application.get_env(:serviceradar_agent_gateway, :camera_media_integration_test_pid) do
      pid when is_pid(pid) -> send(pid, message)
      _other -> :ok
    end
  end
end
