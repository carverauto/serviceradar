defmodule Boombox.InternalBin.ElixirEndpoints do
  @moduledoc false

  import Membrane.ChildrenSpec
  require Membrane.Pad, as: Pad

  alias __MODULE__.{PullSink, PushSink, PullSource, PushSource}
  alias Boombox.InternalBin.Ready
  alias Membrane.FFmpeg.SWScale

  @options_audio_keys [:audio_format, :audio_rate, :audio_channels]

  # the size of the toilet capacity is supposed to handle more or less
  # the burst of packets from one segment of Live HLS stream
  @realtimer_toilet_capacity 10_000

  @type flow_control_mode :: :push | :pull

  @spec create_input(pid(), Boombox.in_raw_data_opts(), flow_control_mode()) :: Ready.t()
  def create_input(producer, options, flow_control_mode) do
    options = parse_options(options, :input)

    builders =
      [:audio, :video]
      |> Enum.filter(&(options[&1] != false))
      |> Map.new(fn
        :video ->
          {:video,
           get_child(:elixir_source)
           |> via_out(Pad.ref(:output, :video))
           |> child(:elixir_stream_swscale_converter, %SWScale.Converter{format: :I420})
           |> child(:elixir_stream_h264_encoder, %Membrane.H264.FFmpeg.Encoder{
             profile: :baseline,
             preset: :ultrafast
           })}

        :audio ->
          {:audio,
           get_child(:elixir_source)
           |> via_out(Pad.ref(:output, :audio))}
      end)

    source_definition =
      case flow_control_mode do
        :push -> %PushSource{producer: producer}
        :pull -> %PullSource{producer: producer}
      end

    spec_builder = child(:elixir_source, source_definition)

    %Ready{track_builders: builders, spec_builder: spec_builder}
  end

  @spec link_output(
          pid(),
          Boombox.out_raw_data_opts(),
          flow_control_mode(),
          Boombox.InternalBin.track_builders(),
          Membrane.ChildrenSpec.t(),
          boolean()
        ) :: Ready.t()
  def link_output(
        consumer,
        options,
        flow_control_mode,
        track_builders,
        spec_builder,
        is_input_realtime
      ) do
    options = parse_options(options, :output)
    pace_control = Map.get(options, :pace_control, true)

    {track_builders, to_ignore} =
      Map.split_with(track_builders, fn {kind, _builder} -> options[kind] != false end)

    sink_definition =
      case flow_control_mode do
        :push -> %PushSink{consumer: consumer}
        :pull -> %PullSink{consumer: consumer}
      end

    spec =
      [
        spec_builder,
        child(:elixir_sink, sink_definition),
        Enum.map(track_builders, fn
          {:audio, builder} ->
            builder
            |> child(:elixir_audio_transcoder, %Membrane.Transcoder{
              output_stream_format: Membrane.RawAudio
            })
            |> maybe_plug_resampler(options)
            |> maybe_plug_realtimer(:audio, pace_control, is_input_realtime)
            |> via_in(Pad.ref(:input, :audio))
            |> get_child(:elixir_sink)

          {:video, builder} ->
            builder
            |> child(:elixir_video_transcoder, %Membrane.Transcoder{
              output_stream_format: Membrane.RawVideo
            })
            |> child(:elixir_rgb_converter, %SWScale.Converter{
              format: :RGB,
              output_width: options[:video_width],
              output_height: options[:video_height]
            })
            |> maybe_plug_realtimer(:video, pace_control, is_input_realtime)
            |> via_in(Pad.ref(:input, :video))
            |> get_child(:elixir_sink)
        end),
        Enum.map(to_ignore, fn {_track, builder} -> builder |> child(Membrane.Debug.Sink) end)
      ]

    %Ready{actions: [spec: spec], eos_info: Map.keys(track_builders)}
  end

  defp maybe_plug_realtimer(builder, kind, pace_control, is_input_realtime)

  defp maybe_plug_realtimer(builder, kind, true, false) do
    builder
    |> via_in(:input, toilet_capacity: @realtimer_toilet_capacity)
    |> child({:elixir, kind, :realtimer}, Membrane.Realtimer)
  end

  defp maybe_plug_realtimer(builder, _kind, _pace_control, _is_input_realtime), do: builder
  @spec parse_options(Boombox.in_raw_data_opts(), :input) :: map()
  @spec parse_options(Boombox.out_raw_data_opts(), :output) :: map()
  defp parse_options(options, direction) do
    audio = Keyword.get(options, :audio)

    audio_keys =
      if direction == :output and audio != false and
           Enum.any?(@options_audio_keys, &Keyword.has_key?(options, &1)),
         do: @options_audio_keys,
         else: []

    options =
      options
      |> Keyword.validate!(
        [:video, :audio, :video_width, :video_height, :pace_control, :is_live] ++ audio_keys
      )
      |> Map.new()

    if options.audio == false and options.video == false do
      raise "Got audio and video options set to false. At least one track must be enabled."
    end

    options
  end

  defp maybe_plug_resampler(builder, %{
         audio_format: format,
         audio_rate: rate,
         audio_channels: channels
       }) do
    format = %Membrane.RawAudio{sample_format: format, sample_rate: rate, channels: channels}

    builder
    |> child(:elixir_stream_resampler, %Membrane.FFmpeg.SWResample.Converter{
      output_stream_format: format
    })
  end

  defp maybe_plug_resampler(builder, _options) do
    builder
  end
end
