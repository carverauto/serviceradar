defmodule ServiceRadarCoreElx.CameraRelay.PipelineManagerTest do
  use ExUnit.Case, async: false

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
end
