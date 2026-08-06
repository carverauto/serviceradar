defmodule Boombox.InternalBin.SRT do
  @moduledoc false
  import Membrane.ChildrenSpec

  require Membrane.Pad, as: Pad

  alias Boombox.InternalBin.{Ready, Wait}
  alias Membrane.{AAC, H264, SRT, Transcoder}

  @type srt_auth_opts :: [stream_id: String.t(), password: String.t()]

  @spec create_input(pid()) :: Wait.t()
  def create_input(server_awaiting_accept) when is_pid(server_awaiting_accept) do
    handle_connection(server_awaiting_accept)
  end

  @spec create_input(String.t(), srt_auth_opts()) :: Wait.t()
  def create_input(url, opts) do
    {ip, port} = parse_srt_url(url)

    stream_id = opts[:stream_id] || ""
    password = opts[:password] || ""

    spec = [
      child(:srt_source, %SRT.Source{ip: ip, port: port, stream_id: stream_id, password: password})
      |> child(:srt_mpeg_ts_demuxer, Membrane.MPEG.TS.Demuxer)
    ]

    %Wait{actions: [spec: spec]}
  end

  @spec handle_connection(pid()) :: Wait.t()
  def handle_connection(server_awaiting_accept) do
    spec = [
      child(:srt_source, %SRT.Source{server_awaiting_accept: server_awaiting_accept})
      |> child(:srt_mpeg_ts_demuxer, Membrane.MPEG.TS.Demuxer)
    ]

    %Wait{actions: [spec: spec]}
  end

  @spec handle_tracks_resolved(term()) :: Ready.t()
  def handle_tracks_resolved(pmt) do
    track_builders =
      Enum.map(pmt.streams, fn {id, %{stream_type: type}} ->
        get_child(:srt_mpeg_ts_demuxer)
        |> via_out(Pad.ref(:output, {:stream_id, id}))
        |> then(
          &case type do
            :H264 ->
              {:video,
               child(&1, :srt_in_h264_parser, %H264.Parser{output_stream_structure: :avc1})}

            :AAC ->
              {:audio,
               child(&1, :srt_in_aac_parser, %AAC.Parser{
                 out_encapsulation: :none,
                 output_config: :esds
               })}
          end
        )
      end)
      |> Map.new()

    %Ready{track_builders: track_builders}
  end

  @spec link_output(
          String.t(),
          srt_auth_opts(),
          Boombox.InternalBin.track_builders(),
          Membrane.ChildrenSpec.t(),
          boolean()
        ) :: Ready.t()
  def link_output(url, opts, track_builders, spec_builder, is_input_realtime) do
    {ip, port} = parse_srt_url(url)

    stream_id = opts[:stream_id] || ""
    password = opts[:password]

    spec =
      [
        spec_builder,
        child(:srt_mpeg_ts_muxer, Membrane.MPEGTS.Muxer)
        |> child(:srt_sink, %SRT.Sink{
          ip: ip,
          port: port,
          stream_id: stream_id,
          password: password
        }),
        Enum.map(track_builders, fn
          {:audio, builder} ->
            builder
            |> child(:srt_mpeg_ts_audio_transcoder, %Transcoder{
              output_stream_format: AAC
            })
            |> then(
              &if is_input_realtime,
                do: &1,
                else: child(&1, :srt_audio_realtimer, Membrane.Realtimer)
            )
            |> via_in(:audio_input)
            |> get_child(:srt_mpeg_ts_muxer)

          {:video, builder} ->
            builder
            |> child(:srt_mpeg_ts_video_transcoder, %Transcoder{
              output_stream_format: %H264{stream_structure: :annexb}
            })
            |> then(
              &if is_input_realtime,
                do: &1,
                else: child(&1, :srt_video_realtimer, Membrane.Realtimer)
            )
            |> via_in(:video_input)
            |> get_child(:srt_mpeg_ts_muxer)
        end)
      ]

    %Ready{actions: [spec: spec]}
  end

  defp parse_srt_url(url) do
    parsed_url = URI.parse(url)
    ip = parsed_url.host
    port = parsed_url.port

    {ip, port}
  end
end
