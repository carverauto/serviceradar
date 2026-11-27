defmodule ServiceRadarCoreElx.CameraRelay.KeyframeCacheTee do
  @moduledoc """
  Push-output tee element that caches the latest H.264 parameter sets
  (SPS/PPS) and current GOP starting from the most recent IDR keyframe.

  When a dynamic output pad attaches to a warm relay stream, the element
  immediately emits the stream format followed by the cached
  `SPS + PPS + IDR` (and subsequent buffered GOP frames) on only the newly
  attached pad before resuming normal live forwarding. When a downstream
  consumer (such as `Membrane.WebRTC.Sink` after DTLS/SRTP setup completes)
  sends an upstream `%Membrane.KeyframeRequestEvent{}` (RTCP PLI), the element
  replays the cached `SPS + PPS + IDR` and current GOP onto only that
  requesting pad, rate-limited per pad by `pli_cooldown_ms`. This lets
  late-joining WebRTC viewers decode their first frame immediately instead of
  waiting for the camera's next natural IDR interval.

  Cache memory per relay is strictly bounded by `max_gop_buffers` and
  `max_gop_bytes`.
  """

  use Membrane.Filter, flow_control_hints?: false

  alias Membrane.Buffer
  alias Membrane.KeyframeRequestEvent
  alias Membrane.Pad

  @nal_type_idr 5
  @nal_type_sps 7
  @nal_type_pps 8

  @default_max_gop_buffers 150
  @default_max_gop_bytes 4 * 1024 * 1024
  @default_pli_cooldown_ms 250

  def_input_pad(:input,
    accepted_format: _any,
    flow_control: :auto
  )

  def_output_pad(:push_output,
    accepted_format: _any,
    availability: :on_request,
    flow_control: :push
  )

  def_options(
    max_gop_buffers: [
      spec: pos_integer(),
      default: @default_max_gop_buffers,
      description: "Maximum number of buffers retained in the cached GOP."
    ],
    max_gop_bytes: [
      spec: pos_integer(),
      default: @default_max_gop_bytes,
      description: "Maximum total payload bytes retained in the cached GOP."
    ],
    pli_cooldown_ms: [
      spec: non_neg_integer(),
      default: @default_pli_cooldown_ms,
      description:
        "Minimum interval in milliseconds between cached GOP replays triggered by KeyframeRequestEvent per pad."
    ]
  )

  @impl true
  def handle_init(_ctx, opts) do
    state = %{
      max_gop_buffers: opts.max_gop_buffers,
      max_gop_bytes: opts.max_gop_bytes,
      pli_cooldown_ms: opts.pli_cooldown_ms,
      last_pli_replay_ms: %{},
      stream_format: nil,
      end_of_stream?: false,
      latest_sps: nil,
      latest_pps: nil,
      gop_sps: nil,
      gop_pps: nil,
      gop_buffers_rev: [],
      gop_count: 0,
      gop_bytes: 0,
      gop_truncated?: false,
      in_idr_au?: false,
      idr_pts: nil
    }

    {[], state}
  end

  @impl true
  def handle_pad_added(Pad.ref(:push_output, _id) = pad, %{playback: :playing}, state) do
    actions =
      case state.stream_format do
        nil ->
          if state.end_of_stream?, do: [end_of_stream: pad], else: []

        stream_format ->
          burst = Enum.map(cached_gop_burst(state), &{:buffer, {pad, &1}})
          eos = if state.end_of_stream?, do: [end_of_stream: pad], else: []
          [{:stream_format, {pad, stream_format}} | burst] ++ eos
      end

    {actions, state}
  end

  def handle_pad_added(Pad.ref(:push_output, _id), _ctx, state) do
    {[], state}
  end

  @impl true
  def handle_pad_removed(Pad.ref(:push_output, _id) = pad, _ctx, state) do
    {[], %{state | last_pli_replay_ms: Map.delete(state.last_pli_replay_ms, pad)}}
  end

  @impl true
  def handle_stream_format(:input, stream_format, ctx, state) do
    actions = Enum.map(output_pads(ctx), &{:stream_format, {&1, stream_format}})
    {actions, %{state | stream_format: stream_format}}
  end

  @impl true
  def handle_buffer(:input, %Buffer{} = buffer, ctx, state) do
    next_state = cache_buffer(state, buffer)
    actions = Enum.map(output_pads(ctx), &{:buffer, {&1, buffer}})
    {actions, next_state}
  end

  @impl true
  def handle_event(:input, event, ctx, state) do
    actions = Enum.map(output_pads(ctx), &{:event, {&1, event}})
    {actions, state}
  end

  def handle_event(
        Pad.ref(:push_output, _id) = pad,
        %KeyframeRequestEvent{} = event,
        %{playback: :playing},
        %{end_of_stream?: false} = state
      ) do
    case cached_gop_burst(state) do
      [] ->
        {[event: {:input, event}], state}

      burst ->
        now_ms = System.monotonic_time(:millisecond)

        if pli_replay_allowed?(state, pad, now_ms) do
          actions = Enum.map(burst, &{:buffer, {pad, &1}})
          next_state = %{state | last_pli_replay_ms: Map.put(state.last_pli_replay_ms, pad, now_ms)}
          {actions, next_state}
        else
          {[], state}
        end
    end
  end

  def handle_event(Pad.ref(:push_output, _id), event, _ctx, state) do
    {[event: {:input, event}], state}
  end

  @impl true
  def handle_end_of_stream(:input, ctx, state) do
    actions = Enum.map(output_pads(ctx), &{:end_of_stream, &1})
    {actions, %{state | end_of_stream?: true}}
  end

  defp pli_replay_allowed?(state, pad, now_ms) do
    case Map.fetch(state.last_pli_replay_ms, pad) do
      :error -> true
      {:ok, last_ms} -> now_ms - last_ms >= state.pli_cooldown_ms
    end
  end

  defp output_pads(ctx) do
    for {pad_ref, %{direction: :output}} <- ctx.pads, do: pad_ref
  end

  defp cache_buffer(state, %Buffer{} = buffer) do
    types = nal_unit_types(buffer)

    cond do
      @nal_type_idr in types ->
        cache_idr_buffer(state, buffer, types)

      @nal_type_sps in types and @nal_type_pps in types ->
        %{state | latest_sps: buffer, latest_pps: nil}

      @nal_type_sps in types ->
        %{state | latest_sps: buffer}

      @nal_type_pps in types ->
        %{state | latest_pps: buffer}

      true ->
        cache_non_idr_buffer(state, buffer)
    end
  end

  defp cache_idr_buffer(state, %Buffer{} = buffer, types) do
    continuation_idr? =
      state.in_idr_au? and state.gop_count > 0 and buffer.pts != nil and buffer.pts == state.idr_pts

    if continuation_idr? do
      append_to_gop(state, buffer, not end_access_unit?(buffer))
    else
      start_new_gop(state, buffer, types)
    end
  end

  defp start_new_gop(state, %Buffer{} = buffer, types) do
    size = byte_size(buffer.payload)
    has_inline_sps? = @nal_type_sps in types
    has_inline_pps? = @nal_type_pps in types

    if size <= state.max_gop_bytes do
      %{
        state
        | gop_sps: if(has_inline_sps?, do: nil, else: state.latest_sps),
          gop_pps: if(has_inline_pps?, do: nil, else: state.latest_pps),
          gop_buffers_rev: [buffer],
          gop_count: 1,
          gop_bytes: size,
          gop_truncated?: false,
          in_idr_au?: not end_access_unit?(buffer),
          idr_pts: buffer.pts
      }
    else
      %{
        state
        | gop_sps: nil,
          gop_pps: nil,
          gop_buffers_rev: [],
          gop_count: 0,
          gop_bytes: 0,
          gop_truncated?: true,
          in_idr_au?: false,
          idr_pts: nil
      }
    end
  end

  defp cache_non_idr_buffer(%{gop_count: 0} = state, _buffer), do: state
  defp cache_non_idr_buffer(%{gop_truncated?: true} = state, _buffer), do: state

  defp cache_non_idr_buffer(state, %Buffer{} = buffer) do
    append_to_gop(state, buffer, false)
  end

  defp append_to_gop(%{gop_truncated?: true} = state, _buffer, in_idr_au?) do
    %{state | in_idr_au?: in_idr_au?}
  end

  defp append_to_gop(state, %Buffer{} = buffer, in_idr_au?) do
    size = byte_size(buffer.payload)

    if state.gop_count + 1 <= state.max_gop_buffers and state.gop_bytes + size <= state.max_gop_bytes do
      %{
        state
        | gop_buffers_rev: [buffer | state.gop_buffers_rev],
          gop_count: state.gop_count + 1,
          gop_bytes: state.gop_bytes + size,
          in_idr_au?: in_idr_au?
      }
    else
      %{state | gop_truncated?: true, in_idr_au?: false}
    end
  end

  defp cached_gop_burst(%{gop_buffers_rev: []}), do: []

  defp cached_gop_burst(state) do
    gop_buffers = Enum.reverse(state.gop_buffers_rev)
    first_idr = hd(gop_buffers)

    prefix =
      [state.gop_sps, state.gop_pps]
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&align_parameter_set(&1, first_idr))

    prefix ++ gop_buffers
  end

  defp align_parameter_set(%Buffer{} = param_buffer, %Buffer{} = idr_buffer) do
    metadata =
      Map.update(param_buffer.metadata || %{}, :h264, %{end_access_unit: false}, fn
        h264 when is_map(h264) -> Map.put(h264, :end_access_unit, false)
        _other -> %{end_access_unit: false}
      end)

    %{
      param_buffer
      | pts: idr_buffer.pts,
        dts: idr_buffer.dts,
        metadata: metadata
    }
  end

  defp end_access_unit?(%Buffer{metadata: %{h264: %{end_access_unit: false}}}), do: false
  defp end_access_unit?(_buffer), do: true

  defp nal_unit_types(%Buffer{payload: payload, metadata: %{payload_format: "nalu"}}) when is_binary(payload) do
    case payload do
      <<0, 0, 0, 1, header, _rest::binary>> -> [Bitwise.band(header, 0x1F)]
      <<0, 0, 1, header, _rest::binary>> -> [Bitwise.band(header, 0x1F)]
      _other -> []
    end
  end

  defp nal_unit_types(%Buffer{payload: payload}) when is_binary(payload) do
    total_size = byte_size(payload)

    payload
    |> :binary.matches(<<0, 0, 1>>)
    |> Enum.reduce([], fn {pos, 3}, acc ->
      header_pos = pos + 3

      if header_pos < total_size do
        [Bitwise.band(:binary.at(payload, header_pos), 0x1F) | acc]
      else
        acc
      end
    end)
    |> Enum.reverse()
  end

  defp nal_unit_types(_buffer), do: []
end
