defmodule ServiceRadarCoreElx.CameraRecording.Sink do
  @moduledoc false
  use Membrane.Sink

  alias Membrane.MP4.Container
  alias ServiceRadarCoreElx.CameraRecording.Boundary

  def_input_pad(:input, flow_control: :auto, accepted_format: Membrane.CMAF.Track)
  def_options(max_fragment_bytes: [spec: pos_integer()])

  @impl true
  def handle_init(_ctx, opts) do
    {[], %{events: [], init_sha256: nil, timescale: nil, max_bytes: opts.max_fragment_bytes, end_ns: nil}}
  end

  @impl true
  def handle_stream_format(:input, format, _ctx, state) do
    with {:ok, boxes, <<>>} <- Container.parse(format.header),
         %{fields: %{timescale: timescale}} when timescale > 0 <-
           Container.get_box(boxes, [:moov, :trak, :mdia, :mdhd]) do
      sha256 = digest(format.header)
      init = %{payload: format.header, sha256: sha256, timescale: timescale, codecs: format.codecs}
      {[], %{state | events: [{:init, init} | state.events], init_sha256: sha256, timescale: timescale}}
    else
      _ -> {[notify_parent: {:error, :invalid_initialization}], state}
    end
  end

  @impl true
  def handle_buffer(:input, buffer, _ctx, state) do
    case fragment(buffer, state) do
      {:ok, fragment} ->
        {[], %{state | events: [{:fragment, fragment} | state.events], end_ns: fragment.start_ns + fragment.duration_ns}}

      {:error, reason} ->
        {[notify_parent: {:error, reason}], state}
    end
  end

  @impl true
  def handle_event(:input, %Boundary{} = boundary, _ctx, state) do
    {[notify_parent: {:complete, Enum.reverse(state.events), boundary}], %{state | events: []}}
  end

  @impl true
  def handle_end_of_stream(:input, _ctx, state) do
    {[notify_parent: {:finished, Enum.reverse(state.events)}], %{state | events: []}}
  end

  # membrane_mp4_plugin 0.36.10 increments chunks_duration for whole video segments without
  # resetting it, so last_chunk? is false even in segment-only mode. Completion
  # here requires exact parsed sample/mdat boundaries; partial mode is never used.
  defp fragment(%{payload: payload, metadata: %{independent?: true}}, state) when byte_size(payload) <= state.max_bytes do
    with {:ok, boxes, <<>>} <- Container.parse(payload),
         %{fields: %{base_media_decode_time: start}} <- Container.get_box(boxes, [:moof, :traf, :tfdt]),
         %{fields: %{samples: [first | _] = samples}} <- Container.get_box(boxes, [:moof, :traf, :trun]),
         <<_::15, 0::1, _::16>> <- first.sample_flags,
         true <- Enum.all?(samples, &(&1.sample_duration > 0 and &1.sample_composition_time_offset == 0)),
         %{content: media} <- Container.get_box(boxes, :mdat),
         sample_bytes = Enum.sum(Enum.map(samples, & &1.sample_size)),
         true <- byte_size(media) == sample_bytes do
      duration = Enum.sum(Enum.map(samples, & &1.sample_duration))
      start_ns = div(start * Membrane.Time.second(), state.timescale)
      end_ns = div((start + duration) * Membrane.Time.second(), state.timescale)

      with :ok <- valid_timing(start_ns, end_ns, state.end_ns) do
        {:ok,
         %{
           payload: payload,
           sha256: digest(payload),
           init_sha256: state.init_sha256,
           start_ns: start_ns,
           duration_ns: end_ns - start_ns,
           independent?: true,
           sample_count: length(samples),
           sample_bytes: sample_bytes
         }}
      end
    else
      _ -> {:error, :invalid_cmaf_fragment}
    end
  end

  defp fragment(_buffer, _state), do: {:error, :incomplete_or_oversized_fragment}

  defp valid_timing(_start_ns, end_ns, _previous_end) when end_ns > 9_223_372_036_854_775_807,
    do: {:error, :timestamp_out_of_range}

  defp valid_timing(start_ns, end_ns, previous_end)
       when end_ns > start_ns and (previous_end == nil or previous_end == start_ns), do: :ok

  defp valid_timing(_start_ns, _end_ns, _previous_end), do: {:error, :non_contiguous_media_timing}

  defp digest(bytes), do: :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)
end
