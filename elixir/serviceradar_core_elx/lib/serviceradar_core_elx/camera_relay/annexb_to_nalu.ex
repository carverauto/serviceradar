defmodule ServiceRadarCoreElx.CameraRelay.AnnexBToNALU do
  @moduledoc """
  Converts Annex B H264 access units into NALU-aligned buffers for WebRTC payloading.

  Each relay chunk is one access unit. `Membrane.RTP.H264.Payloader` sets the
  RTP marker from `metadata.h264.end_access_unit`, so the last NALU of a chunk
  carries it. Chunk timestamps arrive in the 90 kHz H264 RTP clock (the agent
  forwards the RTSP packet PTS, and RFC 6184 fixes H264 at 90 kHz), while the
  WebRTC sink reads buffer timestamps as `Membrane.Time`, so they are converted
  here.
  """

  use Membrane.Filter

  alias Membrane.Buffer
  alias Membrane.H264

  @h264_clock_rate 90_000

  def_input_pad(:input,
    accepted_format: _any,
    flow_control: :auto
  )

  def_output_pad(:output,
    accepted_format: %H264{alignment: :nalu, stream_structure: :annexb},
    flow_control: :auto
  )

  @impl true
  def handle_init(_ctx, _opts) do
    {[], %{stream_format_sent?: false}}
  end

  @impl true
  def handle_stream_format(:input, _stream_format, _ctx, state) do
    {stream_format_actions(state), %{state | stream_format_sent?: true}}
  end

  @impl true
  def handle_buffer(:input, %Buffer{} = buffer, _ctx, state) do
    nalus = split_annexb_nalus(buffer.payload)
    last_index = length(nalus) - 1
    pts = to_membrane_time(buffer.pts)
    dts = to_membrane_time(buffer.dts)

    actions =
      stream_format_actions(state) ++
        Enum.map(Enum.with_index(nalus), fn {nalu, index} ->
          metadata =
            Map.merge(buffer.metadata || %{}, %{
              payload_format: "nalu",
              h264: %{end_access_unit: index == last_index}
            })

          {:buffer, {:output, %Buffer{payload: prefixed_annexb_nalu(nalu), pts: pts, dts: dts, metadata: metadata}}}
        end)

    {actions, %{state | stream_format_sent?: true}}
  end

  defp to_membrane_time(nil), do: nil
  defp to_membrane_time(ticks) when is_integer(ticks), do: div(ticks * Membrane.Time.second(), @h264_clock_rate)

  defp stream_format_actions(%{stream_format_sent?: true}), do: []

  defp stream_format_actions(_state) do
    [stream_format: {:output, %H264{alignment: :nalu, stream_structure: :annexb}}]
  end

  defp split_annexb_nalus(payload) when is_binary(payload) do
    payload
    |> extract_nalus([], <<>>)
    |> Enum.reject(&(byte_size(&1) == 0))
  end

  defp extract_nalus(<<>>, acc, current), do: Enum.reverse(finish_current(acc, current))

  defp extract_nalus(<<0, 0, 1, rest::binary>>, acc, current) do
    extract_nalus(rest, finish_current(acc, current), <<>>)
  end

  defp extract_nalus(<<0, 0, 0, 1, rest::binary>>, acc, current) do
    extract_nalus(rest, finish_current(acc, current), <<>>)
  end

  defp extract_nalus(<<byte, rest::binary>>, acc, current) do
    extract_nalus(rest, acc, <<current::binary, byte>>)
  end

  defp finish_current(acc, <<>>), do: acc
  defp finish_current(acc, current), do: [current | acc]

  defp prefixed_annexb_nalu(nalu), do: <<0, 0, 0, 1, nalu::binary>>
end
