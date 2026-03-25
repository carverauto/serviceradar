# This generates two variants of the Sink:
#   * PullSink - The element has `:manual` flow control on input pads and demands the
#     packets from the previous element when receiving `{:boombox_demand, demand}`
#     messages from the consumer process.
#   * PushSink - The element works has `:push` flow control on input pads and doesn't expect
#     demands from the consumer process.

[{PullSink, :manual}, {PushSink, :push}]
|> Enum.map(fn {module_name, flow_control} ->
  defmodule Module.concat(Boombox.InternalBin.ElixirEndpoints, module_name) do
    @moduledoc false
    use Membrane.Sink

    case flow_control do
      :manual ->
        def_input_pad :input,
          accepted_format: any_of(Membrane.RawAudio, Membrane.RawVideo),
          availability: :on_request,
          max_instances: 2,
          flow_control: :manual,
          demand_unit: :buffers

      :push ->
        def_input_pad :input,
          accepted_format: any_of(Membrane.RawAudio, Membrane.RawVideo),
          availability: :on_request,
          max_instances: 2,
          flow_control: :push
    end

    def_options consumer: [
                  spec: pid(),
                  description: """
                  PID of a process to which send packets.
                  """
                ]

    defmodule State do
      @moduledoc false
      @type t :: %__MODULE__{
              consumer: pid(),
              last_pts: %{
                optional(:video) => Membrane.Time.t(),
                optional(:audio) => Membrane.Time.t()
              },
              audio_format:
                %{
                  audio_format: Membrane.RawAudio.SampleFormat.t(),
                  audio_rate: pos_integer(),
                  audio_channels: pos_integer()
                }
                | nil
            }

      @enforce_keys [:consumer]

      defstruct @enforce_keys ++
                  [
                    last_pts: %{},
                    audio_format: nil
                  ]
    end

    @impl true
    def handle_init(_ctx, opts) do
      {[], %State{consumer: opts.consumer}}
    end

    @impl true
    def handle_pad_added(Pad.ref(:input, kind), _ctx, state) do
      {[], %{state | last_pts: Map.put(state.last_pts, kind, 0)}}
    end

    @impl true
    def handle_playing(_ctx, state) do
      send(state.consumer, {:boombox_elixir_sink, self()})
      {[], state}
    end

    if flow_control == :manual do
      @impl true
      def handle_info({:boombox_demand, consumer}, _ctx, %{consumer: consumer} = state) do
        if state.last_pts == %{} do
          {[], state}
        else
          {kind, _pts} =
            Enum.min_by(state.last_pts, fn {_kind, pts} -> pts end)

          {[demand: Pad.ref(:input, kind)], state}
        end
      end
    end

    @impl true
    def handle_stream_format(Pad.ref(:input, :audio), stream_format, _ctx, state) do
      audio_format = %{
        audio_format: stream_format.sample_format,
        audio_rate: stream_format.sample_rate,
        audio_channels: stream_format.channels
      }

      {[], %{state | audio_format: audio_format}}
    end

    @impl true
    def handle_stream_format(_pad, _stream_format, _ctx, state) do
      {[], state}
    end

    @impl true
    def handle_buffer(Pad.ref(:input, :video), buffer, ctx, state) do
      state = %{state | last_pts: %{state.last_pts | video: buffer.pts}}
      %{width: width, height: height} = ctx.pads[Pad.ref(:input, :video)].stream_format

      {:ok, image} =
        Vix.Vips.Image.new_from_binary(buffer.payload, width, height, 3, :VIPS_FORMAT_UCHAR)

      packet = %Boombox.Packet{
        payload: image,
        pts: buffer.pts,
        kind: :video
      }

      send(state.consumer, {:boombox_packet, self(), packet})

      {[], state}
    end

    @impl true
    def handle_buffer(Pad.ref(:input, :audio), buffer, _ctx, state) do
      state = %{state | last_pts: %{state.last_pts | audio: buffer.pts}}

      packet = %Boombox.Packet{
        payload: buffer.payload,
        pts: buffer.pts,
        kind: :audio,
        format: state.audio_format
      }

      send(state.consumer, {:boombox_packet, self(), packet})

      {[], state}
    end

    @impl true
    def handle_end_of_stream(Pad.ref(:input, kind), _ctx, state) do
      {[], %{state | last_pts: Map.delete(state.last_pts, kind)}}
    end
  end
end)
