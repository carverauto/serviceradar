defmodule Boombox.InternalBin.WebRTC do
  @moduledoc false

  import Membrane.ChildrenSpec
  require Membrane.Pad, as: Pad
  alias Boombox.InternalBin.{Ready, State, Wait}
  alias Membrane.Bin.CallbackContext
  alias Membrane.{H264, RemoteStream, VP8, WebRTC}

  @type output_webrtc_state :: %{negotiated_video_codecs: [:vp8 | :h264] | nil}
  @type webrtc_sink_new_tracks :: [%{id: term, kind: :audio | :video}]

  defguardp is_webrtc(endpoint) when is_tuple(endpoint) and elem(endpoint, 0) == :webrtc
  defguardp has_webrtc_input(state) when is_webrtc(state.input)
  defguardp has_webrtc_output(state) when is_webrtc(state.output)

  @spec create_input(Boombox.webrtc_signaling(), Boombox.output(), CallbackContext.t(), State.t()) ::
          Wait.t()
  def create_input(signaling, output, ctx, state) do
    signaling = resolve_signaling(signaling, :input, ctx.utility_supervisor)

    keyframe_interval =
      case output do
        {:webrtc, _signaling} -> nil
        _other -> Membrane.Time.seconds(2)
      end

    {preferred_video_codec, allowed_video_codecs} =
      resolve_input_webrtc_codec_options(ctx, state)

    spec =
      child(:webrtc_input, %WebRTC.Source{
        signaling: signaling,
        preferred_video_codec: preferred_video_codec,
        allowed_video_codecs: allowed_video_codecs,
        keyframe_interval: keyframe_interval
      })

    %Wait{actions: [spec: spec]}
  end

  @spec handle_input_tracks(WebRTC.Source.new_tracks()) :: Ready.t()
  def handle_input_tracks(tracks) do
    track_builders =
      Map.new(tracks, fn
        %{kind: :audio, id: id} ->
          spec =
            get_child(:webrtc_input)
            |> via_out(Pad.ref(:output, id))

          {:audio, spec}

        %{kind: :video, id: id} ->
          spec =
            get_child(:webrtc_input)
            |> via_out(Pad.ref(:output, id))

          {:video, spec}
      end)

    %Ready{track_builders: track_builders}
  end

  @spec create_output(Boombox.webrtc_signaling(), CallbackContext.t(), State.t()) ::
          {Ready.t() | Wait.t(), State.t()}
  def create_output(signaling, ctx, state) do
    signaling = resolve_signaling(signaling, :output, ctx.utility_supervisor)
    startup_tracks = if has_webrtc_input(state), do: [:audio, :video], else: []

    spec =
      child(:webrtc_output, %WebRTC.Sink{
        signaling: signaling,
        tracks: startup_tracks,
        video_codec: [:vp8, :h264]
      })

    state = %{state | output_webrtc_state: %{negotiated_video_codecs: nil}}

    {status, state} =
      if has_webrtc_input(state) do
        # let's spawn websocket server for webrtc source before the source starts
        {:webrtc, input_signaling} = state.input
        signaling = resolve_signaling(input_signaling, :input, ctx.utility_supervisor)
        state = %{state | input: {:webrtc, signaling}}

        {%Wait{actions: [spec: spec]}, state}
      else
        {%Ready{actions: [spec: spec]}, state}
      end

    {status, state}
  end

  @spec handle_output_video_codecs_negotiated([:h264 | :vp8], State.t()) ::
          {Ready.t() | Wait.t(), State.t()}
  def handle_output_video_codecs_negotiated(codecs, state) do
    state = put_in(state.output_webrtc_state.negotiated_video_codecs, codecs)
    status = if has_webrtc_input(state), do: %Ready{}, else: %Wait{}
    {status, state}
  end

  @spec link_output(
          [Boombox.transcoding_policy_opt()],
          Boombox.InternalBin.track_builders(),
          Membrane.ChildrenSpec.t(),
          webrtc_sink_new_tracks(),
          boolean(),
          State.t()
        ) :: Ready.t() | Wait.t()
  def link_output(opts, track_builders, spec_builder, tracks, is_input_realtime, state) do
    if has_webrtc_input(state) do
      do_link_output(opts, track_builders, spec_builder, tracks, is_input_realtime, state)
    else
      tracks = Bunch.KVEnum.keys(track_builders)
      %Wait{actions: [notify_child: {:webrtc_output, {:add_tracks, tracks}}]}
    end
  end

  @spec handle_output_tracks_negotiated(
          [Boombox.transcoding_policy_opt()],
          Boombox.InternalBin.track_builders(),
          Membrane.ChildrenSpec.t(),
          webrtc_sink_new_tracks(),
          boolean(),
          State.t()
        ) :: Ready.t() | no_return()
  def handle_output_tracks_negotiated(
        opts,
        track_builders,
        spec_builder,
        tracks,
        is_input_realtime,
        state
      ) do
    if has_webrtc_input(state) do
      raise """
      Currently ICE restart is not supported in Boombox instances having WebRTC input and output.
      """
    end

    do_link_output(opts, track_builders, spec_builder, tracks, is_input_realtime, state)
  end

  defp do_link_output(opts, track_builders, spec_builder, tracks, is_input_realtime, state) do
    transcoding_policy = opts |> Keyword.get(:transcoding_policy, :if_needed)
    tracks = Map.new(tracks, &{&1.kind, &1.id})

    spec = [
      spec_builder,
      Enum.map(track_builders, fn
        {:audio, builder} ->
          builder
          |> child(:mp4_audio_transcoder, %Membrane.Transcoder{
            output_stream_format: Membrane.Opus,
            transcoding_policy: transcoding_policy
          })
          |> then(
            &if is_input_realtime,
              do: &1,
              else: child(&1, :webrtc_audio_realtimer, Membrane.Realtimer)
          )
          |> via_in(Pad.ref(:input, tracks.audio), options: [kind: :audio])
          |> get_child(:webrtc_output)

        {:video, builder} ->
          negotiated_codecs = state.output_webrtc_state.negotiated_video_codecs

          builder
          |> then(
            &if is_input_realtime,
              do: &1,
              else: child(&1, :webrtc_video_realtimer, Membrane.Realtimer)
          )
          |> child(:webrtc_video_transcoder, %Membrane.Transcoder{
            output_stream_format: fn input_format ->
              resolve_output_video_stream_format(
                input_format,
                :vp8 in negotiated_codecs,
                :h264 in negotiated_codecs,
                transcoding_policy
              )
            end,
            transcoding_policy: transcoding_policy
          })
          |> via_in(Pad.ref(:input, tracks.video), options: [kind: :video])
          |> get_child(:webrtc_output)
      end)
    ]

    %Ready{actions: [spec: spec], eos_info: Map.values(tracks)}
  end

  defp resolve_output_video_stream_format(
         input_stream_format,
         vp8_negotiated?,
         h264_negotiated?,
         transcoding_policy
       )
       when transcoding_policy in [:if_needed, :never] do
    case input_stream_format do
      %H264{} = h264 when h264_negotiated? ->
        %H264{h264 | alignment: :nalu, stream_structure: :annexb}

      %VP8{} = vp8 when vp8_negotiated? ->
        vp8

      %RemoteStream{content_format: VP8, type: :packetized} = remote_stream
      when vp8_negotiated? ->
        remote_stream

      _format when h264_negotiated? ->
        %H264{alignment: :nalu, stream_structure: :annexb}

      _format when vp8_negotiated? ->
        VP8
    end
  end

  defp resolve_output_video_stream_format(
         _input_stream_format,
         vp8_negotiated?,
         h264_negotiated?,
         :always = _transcoding_policy
       ) do
    # if we have to perform transcoding one way or another, we always choose H264 if it is possilbe,
    # because H264 Encoder comsumes less CPU than VP8 Encoder
    cond do
      h264_negotiated? -> %H264{alignment: :nalu, stream_structure: :annexb}
      vp8_negotiated? -> VP8
    end
  end

  defp resolve_signaling(
         %WebRTC.Signaling{} = signaling,
         _direction,
         _utility_supervisor
       ) do
    signaling
  end

  defp resolve_signaling({:whip, uri, opts}, :input, utility_supervisor) do
    uri = URI.new!(uri)
    {:ok, ip} = :inet.getaddr(~c"#{uri.host}", :inet)
    setup_whip_server([ip: ip, port: uri.port] ++ opts, utility_supervisor)
  end

  defp resolve_signaling({:whip, uri, opts}, :output, utility_supervisor) do
    signaling = WebRTC.Signaling.new()

    Membrane.UtilitySupervisor.start_link_child(
      utility_supervisor,
      {WebRTC.WhipClient, [signaling: signaling, uri: uri] ++ opts}
    )

    signaling
  end

  defp resolve_signaling(uri, _direction, utility_supervisor) when is_binary(uri) do
    uri = URI.new!(uri)
    {:ok, ip} = :inet.getaddr(~c"#{uri.host}", :inet)
    opts = [ip: ip, port: uri.port]

    WebRTC.SimpleWebSocketServer.start_link_supervised(utility_supervisor, opts)
  end

  defp setup_whip_server(opts, utility_supervisor) do
    signaling = WebRTC.Signaling.new()
    clients_cnt = :atomics.new(1, [])
    {valid_token, opts} = Keyword.pop(opts, :token)

    handle_new_client = fn token ->
      cond do
        valid_token not in [nil, token] -> {:error, :invalid_token}
        :atomics.add_get(clients_cnt, 1, 1) > 1 -> {:error, :already_connected}
        true -> {:ok, signaling}
      end
    end

    Membrane.UtilitySupervisor.start_child(utility_supervisor, {
      WebRTC.WhipServer,
      [handle_new_client: handle_new_client] ++ opts
    })

    signaling
  end

  defp resolve_input_webrtc_codec_options(_ctx, state) when has_webrtc_output(state) do
    case state.output_webrtc_state do
      %{negotiated_video_codecs: []} ->
        # preferred_video_codec will be ignored
        {:vp8, []}

      %{negotiated_video_codecs: [codec]} ->
        {codec, [:h264, :vp8]}

      %{negotiated_video_codecs: [_codec_1, _codec_2] = codecs} ->
        {:vp8, codecs}
    end
  end

  # case when Boombox.Bin has pads linked before handle_playing
  defp resolve_input_webrtc_codec_options(ctx, state)
       when state.output == :membrane_pad and map_size(ctx.pads) > 0 do
    output_video_pad_options =
      ctx.pads
      |> Enum.find_value(fn
        {Pad.ref(:output, _id), %{options: %{kind: :video} = options}} -> options
        _pad_entry -> false
      end)

    with %{codec: codec} <- output_video_pad_options do
      preferred_codec =
        case codec do
          [first_codec | _rest] -> first_codec
          atom when is_atom(atom) -> atom
        end
        |> case do
          H264 -> :h264
          VP8 -> :vp8
          _other -> :h264
        end

      {preferred_codec, [:h264, :vp8]}
    else
      nil ->
        # there is no output video pad so video codec shouldn't be negotiated so
        # value returned from this function will be ignored
        {:h264, []}
    end
  end

  # case when Boombox.Bin returns a :new_tracks notification
  defp resolve_input_webrtc_codec_options(ctx, state)
       when state.output == :membrane_pad and map_size(ctx.pads) == 0 do
    {:h264, [:h264, :vp8]}
  end

  defp resolve_input_webrtc_codec_options(_ctx, _state) do
    {:h264, [:h264, :vp8]}
  end
end
