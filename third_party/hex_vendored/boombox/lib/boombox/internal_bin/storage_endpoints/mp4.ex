defmodule Boombox.InternalBin.StorageEndpoints.MP4 do
  @moduledoc false

  import Membrane.ChildrenSpec
  require Membrane.Pad, as: Pad
  alias Boombox.InternalBin.{Ready, Wait}
  alias Boombox.InternalBin.StorageEndpoints
  alias Membrane.H264
  alias Membrane.H265

  defguardp is_h26x(format) when is_struct(format) and format.__struct__ in [H264, H265]

  @spec create_input(String.t(), [{:transport, :file | :http}]) ::
          Wait.t()
  def create_input(location, opts) do
    optimize_for_non_fast_start = opts[:transport] == :file

    spec =
      StorageEndpoints.get_source(location, opts[:transport], optimize_for_non_fast_start)
      |> child(:mp4_demuxer, %Membrane.MP4.Demuxer.ISOM{
        optimize_for_non_fast_start?: optimize_for_non_fast_start
      })

    %Wait{actions: [spec: spec]}
  end

  @spec handle_input_tracks(Membrane.MP4.Demuxer.ISOM.new_tracks_t()) :: Ready.t()
  def handle_input_tracks(tracks) do
    track_builders =
      Map.new(tracks, fn
        {id, %Membrane.AAC{}} ->
          spec =
            get_child(:mp4_demuxer)
            |> via_out(Pad.ref(:output, id))
            |> child(:mp4_in_aac_parser, Membrane.AAC.Parser)

          {:audio, spec}

        {id, video_format} when is_h26x(video_format) ->
          spec =
            get_child(:mp4_demuxer)
            |> via_out(Pad.ref(:output, id))

          {:video, spec}
      end)

    %Ready{track_builders: track_builders}
  end

  @spec link_output(
          String.t(),
          [Boombox.transcoding_policy_opt()],
          Boombox.InternalBin.track_builders(),
          Membrane.ChildrenSpec.t()
        ) :: Ready.t()
  def link_output(location, opts, track_builders, spec_builder) do
    transcoding_policy = opts |> Keyword.get(:transcoding_policy, :if_needed)

    pipeline_tails =
      Enum.map(track_builders, fn
        {:audio, audio_builder} ->
          audio_builder
          |> child(:mp4_audio_transcoder, %Membrane.Transcoder{
            output_stream_format: Membrane.AAC,
            transcoding_policy: transcoding_policy
          })
          |> child(:mp4_out_aac_parser, %Membrane.AAC.Parser{
            out_encapsulation: :none,
            output_config: :esds
          })
          |> via_in(Pad.ref(:input, :audio))
          |> get_child(:mp4_muxer)

        {:video, video_builder} ->
          video_builder
          |> child(:mp4_video_transcoder, %Membrane.Transcoder{
            output_stream_format: fn
              %H264{stream_structure: :annexb} = h264 ->
                %H264{h264 | stream_structure: :avc3, alignment: :au}

              %H265{stream_structure: :annexb} = h265 ->
                %H265{h265 | stream_structure: :hev1, alignment: :au}

              h26x when is_h26x(h26x) ->
                %{h26x | alignment: :au}

              _not_h26x ->
                %H264{stream_structure: :avc3, alignment: :au}
            end,
            transcoding_policy: transcoding_policy
          })
          |> via_in(Pad.ref(:input, :video))
          |> get_child(:mp4_muxer)
      end)

    spec =
      [
        spec_builder,
        child(:mp4_muxer, Membrane.MP4.Muxer.ISOM)
        |> child(:file_sink, %Membrane.File.Sink{location: location})
      ] ++ pipeline_tails

    %Ready{actions: [spec: spec]}
  end
end
