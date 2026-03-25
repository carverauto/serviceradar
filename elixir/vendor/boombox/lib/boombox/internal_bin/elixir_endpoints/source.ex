# This generates two variants of the Source:
#   * PullSource - The element has `:manual` flow control on output pads and
#     handles demands from subsequent element by demanding packets from the producer
#     process with `{:boombox_demand, self(), demand_amount}` messages.
#   * PushSource - The element has `:push` flow control on output pads and expects
#     the producer process to provide it with packets without demanding them.

[{PullSource, :manual}, {PushSource, :push}]
|> Enum.map(fn {module_name, flow_control} ->
  defmodule Module.concat(Boombox.InternalBin.ElixirEndpoints, module_name) do
    @moduledoc false
    use Membrane.Source

    def_output_pad :output,
      accepted_format: any_of(Membrane.RawVideo, Membrane.RawAudio),
      availability: :on_request,
      max_instances: 2,
      flow_control: flow_control

    def_options producer: [
                  spec: pid(),
                  description: """
                  PID of a process from which to demand and receive packets.
                  """
                ]

    defmodule State do
      @moduledoc false
      @type t :: %__MODULE__{
              producer: pid(),
              audio_format:
                %{
                  audio_format: Membrane.RawAudio.SampleFormat.t(),
                  audio_rate: pos_integer(),
                  audio_channels: pos_integer()
                }
                | nil,
              video_dims: %{width: pos_integer(), height: pos_integer()} | nil
            }

      @enforce_keys [:producer]

      defstruct @enforce_keys ++
                  [
                    audio_format: nil,
                    video_dims: nil
                  ]
    end

    @impl true
    def handle_init(_ctx, opts) do
      {[], %State{producer: opts.producer}}
    end

    @impl true
    def handle_playing(_ctx, state) do
      send(state.producer, {:boombox_elixir_source, self()})
      {[], state}
    end

    if flow_control == :manual do
      @impl true
      def handle_demand(Pad.ref(:output, id), _size, _unit, ctx, state) do
        send(state.producer, {:boombox_demand, self(), id, ctx.incoming_demand})
        {[], state}
      end
    end

    @impl true
    def handle_info(
          {:boombox_packet, producer, %Boombox.Packet{kind: :video} = packet},
          _ctx,
          %{producer: producer} = state
        ) do
      image = packet.payload |> Image.flatten!() |> Image.to_colorspace!(:srgb)
      video_dims = %{width: Image.width(image), height: Image.height(image)}
      {:ok, payload} = Vix.Vips.Image.write_to_binary(image)
      buffer = %Membrane.Buffer{payload: payload, pts: packet.pts}

      if video_dims == state.video_dims do
        {[buffer: {Pad.ref(:output, :video), buffer}], state}
      else
        stream_format = %Membrane.RawVideo{
          width: video_dims.width,
          height: video_dims.height,
          pixel_format: :RGB,
          aligned: true,
          framerate: nil
        }

        {[
           stream_format: {Pad.ref(:output, :video), stream_format},
           buffer: {Pad.ref(:output, :video), buffer}
         ], %{state | video_dims: video_dims}}
      end
    end

    @impl true
    def handle_info(
          {:boombox_packet, producer, %Boombox.Packet{kind: :audio} = packet},
          _ctx,
          %{producer: producer} = state
        ) do
      %Boombox.Packet{payload: payload, format: format} = packet
      buffer = %Membrane.Buffer{payload: payload, pts: packet.pts}

      cond do
        format == %{} and state.audio_format == nil ->
          raise "No audio stream format provided"

        format == %{} or format == state.audio_format ->
          {[buffer: {Pad.ref(:output, :audio), buffer}], state}

        true ->
          stream_format = %Membrane.RawAudio{
            sample_format: format.audio_format,
            sample_rate: format.audio_rate,
            channels: format.audio_channels
          }

          {[
             stream_format: {Pad.ref(:output, :audio), stream_format},
             buffer: {Pad.ref(:output, :audio), buffer}
           ], %{state | audio_format: format}}
      end
    end

    @impl true
    def handle_info({:boombox_eos, producer}, ctx, %{producer: producer} = state) do
      actions = Enum.map(ctx.pads, fn {ref, _data} -> {:end_of_stream, ref} end)
      {actions, state}
    end
  end
end)
