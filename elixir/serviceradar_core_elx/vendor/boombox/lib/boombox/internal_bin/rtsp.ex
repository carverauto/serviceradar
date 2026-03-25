defmodule Boombox.InternalBin.RTSP do
  @moduledoc false
  import Membrane.ChildrenSpec

  require Membrane.Pad

  require Membrane.Logger
  alias Boombox.InternalBin.{Ready, State, Wait}
  alias Membrane.RTSP

  @spec create_input(URI.t()) :: Wait.t()
  def create_input(uri) do
    port = Enum.random(5_000..65_000)

    spec =
      child(:rtsp_source, %RTSP.Source{
        transport: {:udp, port, port + 20},
        allowed_media_types: [:video, :audio],
        stream_uri: uri,
        on_connection_closed: :send_eos
      })

    %Wait{actions: [spec: spec]}
  end

  @spec handle_set_up_tracks([RTSP.Source.track()], State.t()) :: {Ready.t(), State.t()}
  def handle_set_up_tracks(tracks, state) do
    {spec, track_builders} =
      Enum.reduce(tracks, {[], %{}}, fn
        %{type: type} = track, {spec, track_builders} when is_map_key(track_builders, type) ->
          Membrane.Logger.warning(
            "Tried to link a track of type #{inspect(type)}, but another track
            of that type has already been received, dropping the track"
          )

          dropping_spec =
            get_child(:rtsp_source)
            |> via_out(Membrane.Pad.ref(:output, track.control_path))
            |> child({:rtsp_in_fake_sink, track.control_path}, Membrane.Fake.Sink)

          {[spec | dropping_spec], track_builders}

        %{rtpmap: %{encoding: "H264"}} = track, {spec, track_builders} ->
          {spss, ppss} =
            case track.fmtp.sprop_parameter_sets do
              nil -> {[], []}
              parameter_sets -> {parameter_sets.sps, parameter_sets.pps}
            end

          video_spec =
            get_child(:rtsp_source)
            |> via_out(Membrane.Pad.ref(:output, track.control_path))
            |> child(:rtsp_in_h264_parser, %Membrane.H264.Parser{spss: spss, ppss: ppss})

          {spec, Map.put(track_builders, :video, video_spec)}

        %{rtpmap: %{encoding: "mpeg4-generic"}, type: :audio} = track, {spec, track_builders} ->
          audio_spec =
            get_child(:rtsp_source)
            |> via_out(Membrane.Pad.ref(:output, track.control_path))
            |> child(:rtsp_in_aac_parser, Membrane.AAC.Parser)

          {spec, Map.put(track_builders, :audio, audio_spec)}

        %{rtpmap: %{encoding: unsupported_encoding}}, _acc ->
          raise "Received unsupported encoding with RTSP: #{inspect(unsupported_encoding)}"
      end)

    {%Ready{actions: [spec: spec], track_builders: track_builders}, state}
  end
end
