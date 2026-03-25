defmodule ServiceRadar.Camera.RelayPlaybackTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Camera.RelayPlayback

  test "derives the default browser playback contract for h264 annexb relays" do
    assert %{
             preferred_playback_transport: "websocket_h264_annexb_webcodecs",
             available_playback_transports: [
               "websocket_h264_annexb_webcodecs",
               "websocket_h264_annexb_jmuxer_mse"
             ],
             playback_codec_hint: "h264",
             playback_container_hint: "annexb",
             playback_transport_requirements: %{
               "websocket_h264_annexb_webcodecs" => ["websocket", "webcodecs", "video_decoder"],
               "websocket_h264_annexb_jmuxer_mse" => ["websocket", "media_source", "mse_h264"]
             }
           } =
             RelayPlayback.browser_metadata(%{
               codec_hint: "h264",
               container_hint: "annexb"
             })
  end

  test "preserves explicit playback transport metadata from an existing snapshot" do
    assert %{
             preferred_playback_transport: "membrane_mse_fmp4",
             available_playback_transports: [
               "membrane_mse_fmp4",
               "websocket_h264_annexb_webcodecs"
             ],
             playback_transport_requirements: %{
               "membrane_mse_fmp4" => ["websocket", "media_source"],
               "websocket_h264_annexb_webcodecs" => ["websocket", "webcodecs", "video_decoder"]
             }
           } =
             RelayPlayback.browser_metadata(%{
               "preferred_playback_transport" => "membrane_mse_fmp4",
               "available_playback_transports" => [
                 "membrane_mse_fmp4",
                 "websocket_h264_annexb_webcodecs"
               ],
               "playback_transport_requirements" => %{
                 "membrane_mse_fmp4" => ["websocket", "media_source"],
                 "websocket_h264_annexb_webcodecs" => ["websocket", "webcodecs", "video_decoder"]
               }
             })
  end

  test "prefers advertised webrtc playback transport when available" do
    assert %{
             preferred_playback_transport: "membrane_webrtc",
             available_playback_transports: [
               "membrane_webrtc",
               "websocket_h264_annexb_webcodecs",
               "websocket_h264_annexb_jmuxer_mse"
             ]
           } =
             RelayPlayback.browser_metadata(%{
               codec_hint: "h264",
               container_hint: "annexb",
               webrtc_playback_transport: "membrane_webrtc"
             })
  end
end
