defmodule ServiceRadarCoreElx.CameraRelay.AnnexBToNALUTest do
  # The WebRTC viewer branch feeds this element into Membrane's H264 RTP
  # payloader. The payloader needs `metadata.h264` to set the RTP marker, and
  # the WebRTC sink turns `pts` into the RTP timestamp as Membrane.Time.
  use ExUnit.Case, async: true

  import Membrane.ChildrenSpec
  import Membrane.Testing.Assertions

  alias Membrane.Buffer
  alias Membrane.Testing
  alias ServiceRadarCoreElx.CameraRelay.AnnexBToNALU

  # One relay chunk per access unit, timestamps in the 90 kHz RTP clock.
  @idr_access_unit <<0, 0, 0, 1, 0x67, 0x42, 0xC0, 0x1E>> <>
                     <<0, 0, 0, 1, 0x68, 0xCE, 0x3C, 0x80>> <>
                     <<0, 0, 0, 1, 0x65>> <> :binary.copy(<<0x88>>, 2_000)
  @slice_access_unit <<0, 0, 0, 1, 0x41>> <> :binary.copy(<<0x9A>>, 300)

  test "relay chunks payload as RTP marked at each access unit end, timed in Membrane.Time" do
    chunks = [
      %Buffer{payload: @idr_access_unit, pts: 900_000, dts: 900_000, metadata: %{keyframe: true}},
      %Buffer{payload: @slice_access_unit, pts: 906_000, dts: 906_000, metadata: %{keyframe: false}}
    ]

    pipeline =
      Testing.Pipeline.start_link_supervised!(
        spec:
          :source
          |> child(%Testing.Source{output: chunks})
          |> child(:nalu, AnnexBToNALU)
          |> child(:payloader, Membrane.RTP.H264.Payloader)
          |> child(:sink, Testing.Sink)
      )

    assert_end_of_stream(pipeline, :sink)
    packets = collect_sink_buffers(pipeline)

    by_access_unit = Enum.chunk_by(packets, & &1.pts)

    assert Enum.map(by_access_unit, &hd(&1).pts) == [
             Membrane.Time.seconds(10),
             Membrane.Time.seconds(10) + div(Membrane.Time.second(), 15)
           ]

    for access_unit <- by_access_unit do
      markers = Enum.map(access_unit, & &1.metadata.rtp.marker)
      assert List.last(markers)
      refute Enum.any?(Enum.drop(markers, -1))
    end
  end

  defp collect_sink_buffers(pipeline, acc \\ []) do
    receive do
      {Testing.Pipeline, ^pipeline, {:handle_child_notification, {{:buffer, buffer}, :sink}}} ->
        collect_sink_buffers(pipeline, [buffer | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
