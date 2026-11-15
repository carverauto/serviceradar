defmodule ServiceRadarRecording.Admission do
  @moduledoc false
  use Membrane.Filter

  alias Membrane.H264.DecoderConfigurationRecord
  alias Membrane.H264.NALuParser
  alias ServiceRadarRecording.Boundary

  # Baseline profiles cannot carry B-frames. Main and High can, so they are
  # admitted only when every sequence parameter set in the stream rules
  # reordering out. The writer derives decode time from presentation time.
  @no_reordering_profiles [:baseline, :constrained_baseline]
  @declared_profiles [:main, :high]

  def_input_pad(:input, flow_control: :auto, accepted_format: Membrane.H264)
  def_output_pad(:output, flow_control: :auto, accepted_format: Membrane.H264)

  def_options(max_keyframe_interval_ns: [spec: pos_integer()], wait_for_keyframe?: [spec: boolean(), default: false])

  @impl true
  def handle_init(_ctx, opts) do
    {[],
     %{
       format: nil,
       last_keyframe_ns: nil,
       max_interval: opts.max_keyframe_interval_ns,
       boundary: nil,
       failed?: false,
       waiting?: opts.wait_for_keyframe?
     }}
  end

  @impl true
  def handle_stream_format(:input, format, _ctx, state) do
    cond do
      format.profile not in (@no_reordering_profiles ++ @declared_profiles) ->
        fail(:unsupported_h264_profile, state)

      format.profile in @declared_profiles and not reordering_excluded?(format) ->
        fail(:h264_frame_reordering, state)

      state.format != nil and state.format != format ->
        fail(:stream_configuration_changed, state)

      true ->
        {[stream_format: {:output, format}], %{state | format: format}}
    end
  end

  @impl true
  def handle_buffer(:input, _buffer, _ctx, %{failed?: true} = state), do: {[], state}

  def handle_buffer(:input, %{metadata: %{h264: %{key_frame?: keyframe?}}} = buffer, _ctx, state)
      when is_boolean(keyframe?) do
    cond do
      state.boundary.accepted_bytes != 0 ->
        fail(:multiple_access_units, state)

      state.last_keyframe_ns == nil and not keyframe? ->
        fail(:keyframe_required, state)

      state.last_keyframe_ns != nil and buffer.dts - state.last_keyframe_ns > state.max_interval ->
        fail(:keyframe_interval_exceeded, state)

      byte_size(buffer.payload) > state.boundary.available_bytes ->
        fail(:buffered_media_limit, state)

      true ->
        boundary = %{state.boundary | accepted_bytes: byte_size(buffer.payload), keyframe?: keyframe?}
        last_keyframe_ns = if keyframe?, do: buffer.dts, else: state.last_keyframe_ns
        state = %{state | boundary: boundary, last_keyframe_ns: last_keyframe_ns, waiting?: false}
        {[buffer: {:output, buffer}], state}
    end
  end

  def handle_buffer(:input, _buffer, _ctx, state), do: fail(:missing_keyframe_metadata, state)

  @impl true
  def handle_event(:input, %Boundary{phase: :begin} = boundary, _ctx, state) do
    {[], %{state | boundary: boundary}}
  end

  def handle_event(:input, %Boundary{phase: :end}, _ctx, %{failed?: false} = state) do
    cond do
      state.boundary.accepted_bytes > 0 ->
        {[event: {:output, %{state.boundary | phase: :end}}], %{state | boundary: nil}}

      state.waiting? ->
        {[notify_parent: :waiting_for_keyframe], %{state | boundary: nil}}

      true ->
        fail(:unparseable_access_unit, state)
    end
  end

  def handle_event(_pad, _event, _ctx, state), do: {[], state}

  defp reordering_excluded?(%{stream_structure: {:avc1, record}}) when is_binary(record) do
    case DecoderConfigurationRecord.parse(record) do
      %{spss: [_ | _] = sets} -> Enum.all?(sets, &sequence_excludes_reordering?/1)
      _ -> false
    end
  rescue
    # The dependency raises on a truncated or malformed record.
    _ -> false
  end

  defp reordering_excluded?(_format), do: false

  # Picture order count type 2 makes output order equal decode order. Otherwise
  # the stream must state a reorder depth of zero in its bitstream restrictions.
  defp sequence_excludes_reordering?(set) do
    case NALuParser.parse(set, {nil, nil}, false, NALuParser.new(:annexb)) do
      {%{status: :valid, type: :sps, parsed_fields: fields}, _parser} ->
        fields[:pic_order_cnt_type] == 2 or fields[:max_num_reorder_frames] == 0

      _ ->
        false
    end
  end

  defp fail(reason, state), do: {[notify_parent: {:error, reason}], %{state | failed?: true}}
end
