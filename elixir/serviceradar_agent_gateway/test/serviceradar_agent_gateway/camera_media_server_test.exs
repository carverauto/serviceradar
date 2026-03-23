defmodule ServiceRadarAgentGateway.CameraMediaServerTest do
  use ExUnit.Case, async: false

  alias ServiceRadarAgentGateway.CameraMediaServer
  alias ServiceRadarAgentGateway.TestSupport.CameraMediaAdapterStub
  alias ServiceRadarAgentGateway.TestSupport.CameraMediaForwarderStub
  alias ServiceRadarAgentGateway.TestSupport.CameraMediaIdentityResolverStub
  alias ServiceRadarAgentGateway.TestSupport.CameraMediaSessionTrackerStub

  setup do
    previous_forwarder = Application.get_env(:serviceradar_agent_gateway, :camera_media_forwarder)

    previous_tracker =
      Application.get_env(:serviceradar_agent_gateway, :camera_media_session_tracker_module)

    previous_identity_resolver =
      Application.get_env(:serviceradar_agent_gateway, :camera_media_identity_resolver)

    previous_test_pid = Application.get_env(:serviceradar_agent_gateway, :camera_media_server_test_pid)

    previous_forwarder_heartbeat =
      Application.get_env(:serviceradar_agent_gateway, :camera_media_forwarder_heartbeat_result)

    previous_forwarder_upload =
      Application.get_env(:serviceradar_agent_gateway, :camera_media_forwarder_upload_result)

    previous_tracker_fetch =
      Application.get_env(:serviceradar_agent_gateway, :camera_media_session_tracker_fetch_result)

    previous_tracker_record =
      Application.get_env(:serviceradar_agent_gateway, :camera_media_session_tracker_record_result)

    previous_tracker_mark_closing =
      Application.get_env(
        :serviceradar_agent_gateway,
        :camera_media_session_tracker_mark_closing_result
      )

    previous_tracker_heartbeat =
      Application.get_env(
        :serviceradar_agent_gateway,
        :camera_media_session_tracker_heartbeat_result
      )

    Application.put_env(
      :serviceradar_agent_gateway,
      :camera_media_forwarder,
      CameraMediaForwarderStub
    )

    Application.put_env(
      :serviceradar_agent_gateway,
      :camera_media_session_tracker_module,
      CameraMediaSessionTrackerStub
    )

    Application.put_env(
      :serviceradar_agent_gateway,
      :camera_media_identity_resolver,
      CameraMediaIdentityResolverStub
    )

    Application.put_env(:serviceradar_agent_gateway, :camera_media_server_test_pid, self())

    on_exit(fn ->
      restore_env(:camera_media_forwarder, previous_forwarder)
      restore_env(:camera_media_session_tracker_module, previous_tracker)
      restore_env(:camera_media_identity_resolver, previous_identity_resolver)
      restore_env(:camera_media_server_test_pid, previous_test_pid)
      restore_env(:camera_media_forwarder_heartbeat_result, previous_forwarder_heartbeat)
      restore_env(:camera_media_forwarder_upload_result, previous_forwarder_upload)
      restore_env(:camera_media_session_tracker_fetch_result, previous_tracker_fetch)
      restore_env(:camera_media_session_tracker_record_result, previous_tracker_record)
      restore_env(:camera_media_session_tracker_mark_closing_result, previous_tracker_mark_closing)
      restore_env(:camera_media_session_tracker_heartbeat_result, previous_tracker_heartbeat)
    end)

    :ok
  end

  test "marks the gateway relay session closing when upstream heartbeat enters drain" do
    Application.put_env(
      :serviceradar_agent_gateway,
      :camera_media_forwarder_heartbeat_result,
      {:ok,
       %Camera.RelayHeartbeatAck{
         accepted: true,
         lease_expires_at_unix: 1_800_000_060,
         message: "core heartbeat accepted during relay drain"
       }}
    )

    Application.put_env(
      :serviceradar_agent_gateway,
      :camera_media_session_tracker_mark_closing_result,
      {:ok, %{status: "closing", close_reason: "upstream relay drain"}}
    )

    Application.put_env(
      :serviceradar_agent_gateway,
      :camera_media_session_tracker_heartbeat_result,
      {:ok, %{status: "closing", lease_expires_at_unix: 1_800_000_060}}
    )

    response =
      CameraMediaServer.heartbeat(
        %Camera.RelayHeartbeat{
          relay_session_id: "relay-gw-drain-1",
          media_ingest_id: "core-media-1",
          agent_id: "agent-1",
          last_sequence: 13,
          sent_bytes: 2_048
        },
        %{adapter: CameraMediaAdapterStub, payload: :test}
      )

    assert response.accepted == true
    assert response.lease_expires_at_unix == 1_800_000_060
    assert response.message == "core heartbeat accepted during relay drain"

    assert_receive {:heartbeat, %Camera.RelayHeartbeat{relay_session_id: "relay-gw-drain-1"}}

    assert_receive {:mark_closing, "relay-gw-drain-1", "core-media-1", %{close_reason: "upstream relay drain"}}

    assert_receive {:heartbeat_tracker, "relay-gw-drain-1", "core-media-1",
                    %{last_sequence: 13, sent_bytes: 2_048, lease_expires_at_unix: 1_800_000_060}}
  end

  test "marks the gateway relay session closing when upstream upload enters drain" do
    Application.put_env(
      :serviceradar_agent_gateway,
      :camera_media_forwarder_upload_result,
      {:ok,
       %Camera.UploadMediaResponse{
         received: true,
         last_sequence: 27,
         message: "media chunks accepted during relay drain"
       }}
    )

    Application.put_env(
      :serviceradar_agent_gateway,
      :camera_media_session_tracker_record_result,
      {:ok, %{status: "active"}}
    )

    Application.put_env(
      :serviceradar_agent_gateway,
      :camera_media_session_tracker_mark_closing_result,
      {:ok, %{status: "closing", close_reason: "upstream relay drain"}}
    )

    response =
      CameraMediaServer.upload_media(
        [
          %Camera.MediaChunk{
            relay_session_id: "relay-gw-upload-drain-1",
            media_ingest_id: "core-media-upload-1",
            agent_id: "agent-1",
            sequence: 27,
            payload: <<0, 1, 2, 3>>
          }
        ],
        %{adapter: CameraMediaAdapterStub, payload: :test}
      )

    assert response.received == true
    assert response.last_sequence == 27
    assert response.message == "media chunks accepted during relay drain"

    assert_receive {:record_chunk, "relay-gw-upload-drain-1", "core-media-upload-1",
                    %{sequence: 27, payload: <<0, 1, 2, 3>>}}

    assert_receive {:upload_media,
                    [
                      %Camera.MediaChunk{
                        relay_session_id: "relay-gw-upload-drain-1",
                        media_ingest_id: "core-media-upload-1",
                        sequence: 27
                      }
                    ]}

    assert_receive {:mark_closing, "relay-gw-upload-drain-1", "core-media-upload-1",
                    %{close_reason: "upstream relay drain"}}
  end

  defp restore_env(key, nil), do: Application.delete_env(:serviceradar_agent_gateway, key)
  defp restore_env(key, value), do: Application.put_env(:serviceradar_agent_gateway, key, value)
end
