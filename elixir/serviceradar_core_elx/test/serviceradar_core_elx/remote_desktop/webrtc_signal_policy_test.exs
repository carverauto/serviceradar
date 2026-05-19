defmodule ServiceRadarCoreElx.RemoteDesktop.WebRTCSignalPolicyTest do
  use ExUnit.Case, async: true

  alias ServiceRadarCoreElx.RemoteDesktop.WebRTCSignalPolicy

  test "accepts desktop answers with application and allowlisted video codecs" do
    assert :ok = WebRTCSignalPolicy.validate_answer_sdp(valid_answer_sdp())
  end

  test "rejects repeated media sections" do
    sdp = valid_answer_sdp() <> "\r\nm=video 9 UDP/TLS/RTP/SAVPF 96\r\na=rtpmap:96 VP8/90000"

    assert {:error, :duplicate_media_section} = WebRTCSignalPolicy.validate_answer_sdp(sdp)
  end

  test "rejects unsupported media and codec choices" do
    audio_sdp =
      """
      v=0
      a=fingerprint:sha-256 AA:BB
      m=audio 9 UDP/TLS/RTP/SAVPF 111
      a=rtpmap:111 opus/48000/2
      """

    h265_sdp =
      """
      v=0
      a=fingerprint:sha-256 AA:BB
      m=video 9 UDP/TLS/RTP/SAVPF 96
      a=rtpmap:96 H265/90000
      """

    assert {:error, :unsupported_media_type} = WebRTCSignalPolicy.validate_answer_sdp(audio_sdp)
    assert {:error, :unsupported_video_codec} = WebRTCSignalPolicy.validate_answer_sdp(h265_sdp)
  end

  test "requires sha-256 or stronger DTLS fingerprints" do
    sdp =
      """
      v=0
      a=fingerprint:sha-1 AA:BB
      m=application 9 UDP/DTLS/SCTP webrtc-datachannel
      """

    assert {:error, :unsupported_dtls_fingerprint} = WebRTCSignalPolicy.validate_answer_sdp(sdp)
  end

  test "rejects embedded and trickled private ICE candidates" do
    sdp =
      """
      v=0
      a=fingerprint:sha-256 AA:BB
      m=application 9 UDP/DTLS/SCTP webrtc-datachannel
      a=candidate:1 1 UDP 2122252543 10.0.0.4 54321 typ host
      """

    assert {:error, :blocked_ice_candidate} = WebRTCSignalPolicy.validate_answer_sdp(sdp)

    assert {:error, :blocked_ice_candidate} =
             WebRTCSignalPolicy.validate_ice_candidate(%{
               "candidate" => "candidate:1 1 UDP 2122252543 host.local 54321 typ host"
             })

    assert {:error, :blocked_ice_candidate} =
             WebRTCSignalPolicy.validate_ice_candidate(%{
               "candidate" => "candidate:1 1 UDP 2122252543 fc00::1 54321 typ host"
             })

    assert {:error, :invalid_ice_candidate} =
             WebRTCSignalPolicy.validate_ice_candidate(%{
               "candidate" => "candidate:1 1 UDP 2122252543 relay.example.com 54321 typ relay"
             })
  end

  test "accepts public trickled ICE candidates" do
    assert :ok =
             WebRTCSignalPolicy.validate_ice_candidate(%{
               "candidate" => "candidate:1 1 UDP 2122252543 8.8.8.8 54321 typ srflx"
             })
  end

  defp valid_answer_sdp do
    """
    v=0
    o=- 0 0 IN IP4 127.0.0.1
    s=-
    t=0 0
    a=fingerprint:sha-256 AA:BB:CC:DD
    m=application 9 UDP/DTLS/SCTP webrtc-datachannel
    a=sctp-port:5000
    m=video 9 UDP/TLS/RTP/SAVPF 96 97
    a=rtpmap:96 VP8/90000
    a=rtpmap:97 rtx/90000
    """
  end
end
