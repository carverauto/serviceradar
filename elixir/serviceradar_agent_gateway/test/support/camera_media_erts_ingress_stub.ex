defmodule ServiceRadarAgentGateway.TestSupport.CameraMediaErtsIngressStub do
  @moduledoc false

  use GenServer

  @max_chunk_bytes 262_144

  def open_relay_session(%Camera.OpenRelaySessionRequest{} = request) do
    notify({:core_open_relay_session, request})

    {:ok, ingress_pid} = GenServer.start(__MODULE__, request)

    {:ok,
     %Camera.OpenRelaySessionResponse{
       accepted: true,
       message: "core relay session accepted",
       media_ingest_id: media_ingest_id(),
       max_chunk_bytes: @max_chunk_bytes,
       lease_expires_at_unix: lease_expires_at_unix()
     }, %{ingress_pid: ingress_pid, core_node: node(ingress_pid)}}
  end

  @impl true
  def init(request) do
    {:ok, %{request: request}}
  end

  @impl true
  def handle_call({:upload_media, chunks}, _from, state) do
    notify({:core_upload_media, chunks})

    last_sequence =
      case List.last(chunks) do
        %Camera.MediaChunk{sequence: sequence} -> sequence
        _other -> 0
      end

    {:reply,
     {:ok,
      %Camera.UploadMediaResponse{
        received: true,
        last_sequence: last_sequence,
        message: upload_message()
      }}, state}
  end

  def handle_call({:heartbeat, %Camera.RelayHeartbeat{} = request}, _from, state) do
    notify({:core_heartbeat, request})

    {:reply,
     {:ok,
      %Camera.RelayHeartbeatAck{
        accepted: true,
        lease_expires_at_unix: heartbeat_lease_expires_at_unix(),
        message: heartbeat_message()
      }}, state}
  end

  def handle_call({:close_relay_session, %Camera.CloseRelaySessionRequest{} = request}, _from, state) do
    notify({:core_close_relay_session, request})

    {:stop, :normal, {:ok, %Camera.CloseRelaySessionResponse{closed: true, message: close_message()}}, state}
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
