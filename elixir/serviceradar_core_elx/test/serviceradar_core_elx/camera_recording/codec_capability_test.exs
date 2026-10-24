Code.require_file("../../fixtures/camera_codec_capability.exs", __DIR__)

defmodule ServiceRadarCoreElx.CameraRecording.CodecCapabilityTest do
  use ExUnit.Case, async: false

  test "pinned native A/V and HEVC candidates preserve independently generated frames, markers and timing" do
    output = Path.join(System.tmp_dir!(), "codec-proof-#{System.unique_integer([:positive])}.json")
    on_exit(fn -> File.rm(output) end)
    ffmpeg = Path.expand("../../third_party/membrane/media_test_tools/ffmpeg")
    report = CameraCodecCapability.generate(ffmpeg, output)
    assert Enum.map(report.cases, & &1.name) == ["h264_aac", "h264_aac_delayed", "hevc_main8"]
  end
end
