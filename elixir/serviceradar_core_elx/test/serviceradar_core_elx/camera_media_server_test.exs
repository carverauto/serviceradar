defmodule ServiceRadarCoreElx.CameraMediaServerTest do
  use ExUnit.Case, async: true

  alias ServiceRadarCoreElx.CameraMediaServer
  alias ServiceRadarCoreElx.TestSupport.CameraMediaSessionTrackerStub

  setup do
    previous_tracker =
      Application.get_env(:serviceradar_core_elx, :camera_media_session_tracker_module)

    previous_test_pid = Application.get_env(:serviceradar_core_elx, :camera_media_server_test_pid)
    previous_heartbeat = Application.get_env(:serviceradar_core_elx, :camera_media_server_heartbeat_result)

    previous_record_chunk =
      Application.get_env(:serviceradar_core_elx, :camera_media_server_record_chunk_result)

    Application.put_env(
      :serviceradar_core_elx,
      :camera_media_session_tracker_module,
      CameraMediaSessionTrackerStub
    )

    Application.put_env(:serviceradar_core_elx, :camera_media_server_test_pid, self())

    on_exit(fn ->
      restore_env(:camera_media_session_tracker_module, previous_tracker)
      restore_env(:camera_media_server_test_pid, previous_test_pid)
      restore_env(:camera_media_server_heartbeat_result, previous_heartbeat)
      restore_env(:camera_media_server_record_chunk_result, previous_record_chunk)
    end)

    :ok
  end

  test "returns a draining heartbeat acknowledgment for a closing relay" do
    Application.put_env(
      :serviceradar_core_elx,
      :camera_media_server_heartbeat_result,
      {:ok, %{lease_expires_at_unix: 1_800_000_030, status: "closing"}}
    )

    response =
      CameraMediaServer.heartbeat(
        %Camera.RelayHeartbeat{
          relay_session_id: "relay-closing-1",
          media_ingest_id: "core-media-1",
          last_sequence: 11,
          sent_bytes: 1_024
        },
        nil
      )

    assert response.accepted == true
    assert response.lease_expires_at_unix == 1_800_000_030
    assert response.message == "core heartbeat accepted during relay drain"

    assert_receive {:heartbeat, "relay-closing-1", "core-media-1", %{last_sequence: 11, sent_bytes: 1_024}}
  end

  test "returns a draining upload acknowledgment for a closing relay" do
    Application.put_env(
      :serviceradar_core_elx,
      :camera_media_server_record_chunk_result,
      {:ok, %{status: "closing"}}
    )

    response =
      CameraMediaServer.upload_media(
        [
          %Camera.MediaChunk{
            relay_session_id: "relay-closing-2",
            media_ingest_id: "core-media-2",
            sequence: 27,
            payload: <<1, 2, 3>>,
            codec: "h264",
            payload_format: "annexb"
          }
        ],
        nil
      )

    assert response.received == true
    assert response.last_sequence == 27
    assert response.message == "media chunks accepted during relay drain"

    assert_receive {:record_chunk, "relay-closing-2", "core-media-2",
                    %{sequence: 27, payload: <<1, 2, 3>>, codec: "h264", payload_format: "annexb"}}
  end

  defp restore_env(key, nil), do: Application.delete_env(:serviceradar_core_elx, key)
  defp restore_env(key, value), do: Application.put_env(:serviceradar_core_elx, key, value)
end
