defmodule Boombox.Bin do
  @moduledoc """
  `Boombox.Bin` is a Membrane Bin for audio and video streaming.
  It can be used as a Sink or Source in your Membrane Pipeline.

  If you use it as a Membrane Source and link `:output` pad, you
  have to specify `:input` option, e.g.
  ```elixir
  child(:boombox, %Boombox.Bin{
    input: "path/to/input/file.mp4"
  })
  |> via_out(:output, options: [kind: :audio])
  |> child(:my_audio_sink, My.Audio.Sink)
  ```

  If you use it as a Membrane Sink and link `:input` pad, you have
  to specify `:output` option, e.g.
  ```elixir
  child(:my_video_source, My.Video.Source)
  |> via_in(:input, options: [kind: :video])
  |> child(:boombox, %Boombox.Bin{
    output: "path/to/output/file.mp4"
  })
  ```

  `Boombox.Bin` cannot have `:input` and `:output` pads linked at
  the same time.

  `Boombox.Bin` cannot have `:input` and `:output` options set
  at the same time.

  If you use Boombox.Bin as a source, you can either:
    * link output pads in the same spec where you spawn it
    * or wait until Boombox.Bin returns a notification `{:new_tracks, [:audio | :video]}`
      and then link the pads according to the notification.
  """

  use Membrane.Bin

  require Membrane.Pad, as: Pad
  require Membrane.Transcoder.{Audio, Video}

  alias Membrane.{AAC, H264, Opus, RawAudio, RawVideo, Transcoder, VP8, VP9}

  @allowed_codecs %{
    audio: [AAC, Opus, RawAudio],
    video: [H264, VP8, VP9, RawVideo]
  }

  @typedoc """
  Type of notification sent to the parent of Boombox.Bin when new tracks arrive.

  It is sent only when Boombox.Bin is used as a source (the `:input` option is set).

  This notification is sent by Boombox.Bin only if its pads weren't linked
  before `handle_playing/2` callback.
  """
  @type new_tracks :: {:new_tracks, [:video | :audio]}

  def_input_pad :input,
    accepted_format:
      format
      when Transcoder.Audio.is_audio_format(format) or Transcoder.Video.is_video_format(format),
    availability: :on_request,
    max_instances: 2,
    options: [
      kind: [
        spec: :video | :audio,
        description: """
        Specifies, if the input pad is for audio or video.

        There might be up to one pad of each kind at the time.
        """
      ]
    ]

  def_output_pad :output,
    accepted_format:
      format
      when Transcoder.Audio.is_audio_format(format) or Transcoder.Video.is_video_format(format),
    availability: :on_request,
    max_instances: 2,
    options: [
      kind: [
        spec: :video | :audio,
        description: """
        Specifies, if the output pad is for audio or video.

        There might be up to one pad of each kind at the time.
        """
      ],
      codec: [
        spec:
          H264
          | VP8
          | VP9
          | AAC
          | Opus
          | RawVideo
          | RawAudio
          | [H264 | VP8 | VP9 | AAC | Opus | RawVideo | RawAudio]
          | nil,
        default: nil,
        description: """
        Specifies the codec of the stream flowing through the pad.

        Can be either a single codec or a list of codecs.

        If a list is provided
          * and the stream matches one of the codecs, the matching codec will be used,
          * and the stream doesn't match any of the codecs, it will be transcoded to
            the first codec in the list.

        If the codec is not specified, it will be resolved to:
          * `Membrane.H264` for video,
          * `Membrane.AAC` for audio, if the input is not WebRTC,
          * `Membrane.Opus` for audio, if the input is WebRTC.
        """
      ],
      transcoding_policy: [
        spec: :always | :if_needed | :never,
        default: :if_needed,
        description: """
        Specifies the transcoding policy for the stream flowing through the pad.

        Can be either `:always`, `:if_needed`, or `:never`.

        If set to `:always`, the media stream will be decoded and/or encoded, even if the
        format of the stream arriving at the #{inspect(__MODULE__)} endpoint matches the
        output pad codec. This option is useful when you want to make sure keyframe request
        events going upstream the output pad are handled in Boombox when the Boombox input
        itself cannot handle them (i.e. when the input is not WebRTC).

        If set to `:if_needed`, the media stream will be transcoded only if the format of
        the stream arriving at the #{inspect(__MODULE__)} endpoint doesn't match the output
        pad codec.
        This is the default behavior.

        If set to `:never`, the input media stream won't be decoded or encoded.
        Changing alignment, encapsulation, or stream structure is still possible. This option
        is helpful when you want to ensure that #{inspect(__MODULE__)} will not use too many
        resources, e.g., CPU or memory.

        If the stream arriving at the #{inspect(__MODULE__)} endpoint doesn't match the output
        pad codec, an error will be raised.
        """
      ]
    ]

  def_options input: [
                spec: Boombox.input() | nil,
                default: nil
              ],
              output: [
                spec: Boombox.output() | nil,
                default: nil
              ]

  @impl true
  def handle_init(_ctx, opts) do
    :ok = validate_opts!(opts)

    spec =
      child(:boombox, %Boombox.InternalBin{
        input: opts.input || :membrane_pad,
        output: opts.output || :membrane_pad,
        parent: self()
      })

    {[spec: spec], Map.from_struct(opts)}
  end

  @impl true
  def handle_pad_added(Pad.ref(pad_name, _id) = pad_ref, ctx, state) do
    :ok = validate_pads!(ctx.pads)

    pad_options = Map.to_list(ctx.pad_options)

    spec =
      case pad_name do
        :input ->
          bin_input(pad_ref)
          |> via_in(:input, options: pad_options)
          |> get_child(:boombox)

        :output ->
          get_child(:boombox)
          |> via_out(:output, options: pad_options)
          |> bin_output(pad_ref)
      end

    {[spec: spec], state}
  end

  @impl true
  def handle_child_notification(:processing_finished, :boombox, _ctx, state) do
    {[notify_parent: :processing_finished], state}
  end

  @impl true
  def handle_child_notification({:new_tracks, tracks}, :boombox, _ctx, state) do
    {[notify_parent: {:new_tracks, tracks}], state}
  end

  defp validate_opts!(opts) do
    nil_opts_number =
      [opts.input, opts.output]
      |> Enum.count(&(&1 == nil))

    case nil_opts_number do
      0 ->
        raise """
        #{inspect(__MODULE__)} cannot accept input and output options at the same time, but both were provided.\
        Input: #{inspect(opts.input)}, output: #{inspect(opts.output)}.
        """

      1 ->
        :ok

      2 ->
        raise "#{inspect(__MODULE__)} requires either input or output option to be set, but none were provided."
    end

    [:input, :output]
    |> Enum.each(fn direction ->
      option = opts |> Map.get(direction)

      if is_tuple(option) and elem(option, 0) == :stream do
        raise """
        #{inspect(direction)} option is set to #{inspect(option)}, but #{inspect(__MODULE__)} \
        doesn't support Elixir Stream as an endpoint.
        """
      end
    end)
  end

  defp validate_pads!(pads) do
    pads
    |> Enum.each(fn {pad_ref, %{options: options}} ->
      if Pad.name_by_ref(pad_ref) == :output do
        :ok = validate_codec_pad_option!(pad_ref, options.codec, options.kind)
      end
    end)

    pads
    |> Enum.group_by(fn {Pad.ref(name, _id), %{options: %{kind: kind}}} ->
      {name, kind}
    end)
    |> Enum.find(fn {_key, pads} -> length(pads) > 1 end)
    |> case do
      nil ->
        :ok

      {_key, pads} ->
        raise """
        #{inspect(__MODULE__)} supports only one input and one output pad of each kind. \
        Found multiple pads of the same direction and kind: #{Map.keys(pads) |> inspect()}
        """
    end
  end

  defp validate_codec_pad_option!(pad_ref, codec, kind) do
    codecs = Bunch.listify(codec)

    if codecs == [nil] or codecs -- @allowed_codecs[kind] == [] do
      :ok
    else
      raise """
      Pad #{inspect(pad_ref)} is of kind #{inspect(kind)} and it has :codec option set \
      to  #{inspect(codec)}. \
      Supported codecs for #{inspect(kind)} kind are: #{inspect(@allowed_codecs[kind])}.
      """
    end
  end
end
