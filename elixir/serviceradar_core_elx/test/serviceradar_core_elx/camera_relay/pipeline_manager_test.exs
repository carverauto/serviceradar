defmodule ServiceRadarCoreElx.CameraRelay.PipelineManagerTest do
  use ExUnit.Case, async: false

  alias Membrane.WebRTC.Signaling
  alias ServiceRadar.Camera.RelayPubSub
  alias ServiceRadarCoreElx.CameraRelay.PipelineManager

  test "pipes media chunks through membrane and republishes them to relay pubsub" do
    relay_session_id = "relay-membrane-1"
    viewer_id = "viewer-membrane-1"
    :ok = RelayPubSub.subscribe_viewer(relay_session_id, viewer_id)
    :ok = RelayPubSub.viewer_join(relay_session_id, viewer_id)
    _ = :sys.get_state(ServiceRadarCoreElx.CameraRelay.ViewerRegistry)

    assert {:ok, _session} = PipelineManager.open_session(%{relay_session_id: relay_session_id})

    assert :ok =
             PipelineManager.record_chunk(relay_session_id, %{
               media_ingest_id: "core-media-1",
               sequence: 11,
               pts: 33_000_000,
               dts: 33_000_000,
               codec: "h264",
               payload_format: "annexb",
               track_id: "video",
               keyframe: true,
               payload: <<0, 0, 0, 1, 103, 100, 0, 31>>
             })

    assert_receive {:camera_relay_viewer_chunk,
                    %{
                      relay_session_id: ^relay_session_id,
                      viewer_id: ^viewer_id,
                      media_ingest_id: "core-media-1",
                      sequence: 11,
                      pts: 33_000_000,
                      dts: 33_000_000,
                      codec: "h264",
                      payload_format: "annexb",
                      track_id: "video",
                      keyframe: true,
                      payload: <<0, 0, 0, 1, 103, 100, 0, 31>>
                    }},
                   1_000

    assert :ok = PipelineManager.close_session(relay_session_id)
  end

  test "attaches a webrtc viewer and emits an SDP offer" do
    relay_session_id = "relay-webrtc-1"
    viewer_session_id = "viewer-webrtc-1"

    assert {:ok, _session} = PipelineManager.open_session(%{relay_session_id: relay_session_id})
    {:ok, signaling_pid} = Signaling.start_link([])
    signaling = Signaling.new(signaling_pid)
    :ok = Signaling.register_peer(signaling, message_format: :json_data, pid: self())

    assert :ok =
             PipelineManager.add_webrtc_viewer(
               relay_session_id,
               viewer_session_id,
               signaling,
               ice_servers: []
             )

    assert_receive {:membrane_webrtc_signaling, ^signaling_pid, %{"type" => "sdp_offer", "data" => %{"sdp" => sdp}},
                    _metadata},
                   5_000

    assert is_binary(sdp)
    assert String.contains?(sdp, "m=video")

    assert :ok = PipelineManager.remove_webrtc_viewer(relay_session_id, viewer_session_id)
    assert :ok = PipelineManager.close_session(relay_session_id)
  end
end
