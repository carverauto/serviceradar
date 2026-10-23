defmodule ServiceRadarCoreElx.CameraRecording.Packaging do
  @moduledoc """
  Bounded H264 access-unit to CMAF packaging, isolated from the live relay.

  `start/1` requires `:clock` with a nonempty `:clock_epoch`, positive integer
  `:timebase` (ticks per second), `dts_source: :pts_no_reordering`, and
  `utc_mapping: :unknown` or an explicit mapping containing `:origin_media_ticks`,
  `:origin_utc_usec` and `:uncertainty_usec`. Receive time is not capture time.
  Only baseline/constrained-baseline streams are admitted; equal PTS/DTS alone
  does not establish that an arbitrary H264 profile has no frame reordering.

  The starting process owns the instance. Sequential `push/2` calls take one
  complete AnnexB AU with integer `:pts` and `:dts` in the declared timebase and
  return `{:ok, events}`. Events are `{:init, map}` and `{:fragment, map}`, with
  binary `:payload` and hexadecimal `:sha256`. Fragments include verified MP4
  `:start_ns`, `:duration_ns`, `:independent?`, and `:init_sha256`.

  Byte/sample bounds, media keyframe interval and wall-clock keyframe wait are separate.
  One AU is in flight at a time; the caller must consume returned events before
  pushing again. A failure closes admission and releases all media children.
  A failure outside a pending call sends the owner one
  `{Packaging, pipeline_pid, {:error, reason}}` notification.
  The owner must start a new instance after reconnect, clock reset, or codec
  configuration change. No automatic restart can silently join those epochs.

  `wait_for_keyframe?: true` allows attachment mid-stream. The native parser must
  establish in-band configuration and an IDR. Every initial AU, including one
  the parser drops, consumes cumulative byte/sample admission until acquisition.
  Media and wall-clock wait limits apply independently; no metadata keyframe hint
  or fabricated parameter set can bypass this gate. Strict admission is default.

  `finish/1` flushes a tail containing at least two pending samples; its final
  sample duration is inferred from the preceding sample by the pinned muxer,
  and is labelled `:previous_sample` on the returned fragment. A one-sample tail
  is rejected instead of fabricating its duration. `stop/1` discards the tail.
  Packaging makes no durability claim; the caller owns append/journal receipts.
  Limits are trusted recorder configuration with finite ceilings. Unknown options,
  oversized clock context and timestamps beyond signed 64-bit nanoseconds fail admission.
  """
  use Membrane.Pipeline

  alias Membrane.Buffer
  alias Membrane.Pad
  alias ServiceRadarCoreElx.CameraRecording.Admission
  alias ServiceRadarCoreElx.CameraRecording.Sink
  alias ServiceRadarCoreElx.CameraRecording.Source

  @defaults [
    max_access_unit_bytes: 1_048_576,
    max_buffered_bytes: 8_388_608,
    max_buffered_samples: 1_024,
    max_fragment_bytes: 8_388_608,
    segment_min_duration_ns: 2_000_000_000,
    max_keyframe_interval_ns: 5_000_000_000,
    max_keyframe_wait_ms: 10_000
  ]
  @max_timestamp_ns 9_223_372_036_854_775_807
  @ceilings %{
    max_access_unit_bytes: 8_388_608,
    max_buffered_bytes: 33_554_432,
    max_buffered_samples: 8_192,
    max_fragment_bytes: 33_554_432,
    segment_min_duration_ns: 60_000_000_000,
    max_keyframe_interval_ns: 60_000_000_000,
    max_keyframe_wait_ms: 60_000
  }

  def start(opts) do
    limits = Map.new(Keyword.merge(@defaults, Keyword.take(opts, Keyword.keys(@defaults))))
    clock = Keyword.get(opts, :clock)
    waiting? = Keyword.get(opts, :wait_for_keyframe?, false)

    with true <- valid_clock?(clock),
         true <- is_boolean(waiting?),
         true <- Enum.all?(Keyword.keys(opts), &(&1 in [:clock, :wait_for_keyframe? | Keyword.keys(@defaults)])),
         true <- Enum.all?(limits, fn {key, value} -> is_integer(value) and value in 1..@ceilings[key] end),
         {:ok, _supervisor, pipeline} <-
           Membrane.Pipeline.start(__MODULE__, %{clock: clock, limits: limits, owner: self(), waiting?: waiting?}) do
      {:ok, pipeline}
    else
      false -> {:error, :invalid_packaging_options}
      {:error, _} = error -> error
    end
  end

  def push(pipeline, access_unit), do: call(pipeline, {:push, access_unit})
  def finish(pipeline), do: call(pipeline, :finish)
  def stop(pipeline), do: Membrane.Pipeline.terminate(pipeline, force?: true)

  defp call(pipeline, message) do
    Membrane.Pipeline.call(pipeline, message, 5_000)
  catch
    :exit, {:timeout, _} ->
      stop(pipeline)
      {:error, :packaging_timeout}

    :exit, _reason ->
      {:error, :packaging_stopped}
  end

  @impl true
  def handle_init(_ctx, %{limits: limits} = opts) do
    spec =
      :source
      |> child(Source)
      |> child(:parser, %Membrane.H264.Parser{
        output_alignment: :au,
        output_stream_structure: :avc1,
        skip_until_keyframe: opts.waiting?
      })
      |> child(:admission, %Admission{
        max_keyframe_interval_ns: limits.max_keyframe_interval_ns,
        wait_for_keyframe?: opts.waiting?
      })
      |> via_in(Pad.ref(:input, :video))
      |> child(:muxer, %Membrane.MP4.Muxer.CMAF{segment_min_duration: limits.segment_min_duration_ns})
      |> via_out(Pad.ref(:output, :video), options: [tracks: [:video]])
      |> child(:sink, %Sink{max_fragment_bytes: limits.max_fragment_bytes})

    state =
      Map.merge(opts, %{
        owner_monitor: Process.monitor(opts.owner),
        pending: nil,
        buffered_bytes: 0,
        buffered_samples: 0,
        acquisition_bytes: 0,
        acquisition_samples: 0,
        acquisition_start_ns: nil,
        last_dts: nil,
        timer: nil,
        timer_id: nil,
        error: nil,
        finished?: false
      })

    state = if state.waiting?, do: arm_timer(state), else: state
    {[spec: spec], state}
  end

  @impl true
  def handle_call(_message, %{from: {caller, _}}, %{owner: owner} = state) when caller != owner,
    do: {[reply: {:error, :not_packaging_owner}], state}

  def handle_call(_message, _ctx, %{error: reason} = state) when reason != nil, do: {[reply: {:error, reason}], state}

  def handle_call(_message, _ctx, %{pending: pending} = state) when pending != nil,
    do: {[reply: {:error, :packaging_busy}], state}

  def handle_call(:finish, _ctx, %{finished?: true} = state), do: {[reply: {:ok, []}], state}

  def handle_call(_message, _ctx, %{finished?: true} = state), do: {[reply: {:error, :packaging_finished}], state}

  def handle_call({:push, _access_unit}, ctx, state) when state.buffered_samples >= state.limits.max_buffered_samples,
    do: fail(:buffered_sample_limit, %{state | pending: ctx.from})

  def handle_call({:push, access_unit}, ctx, state) do
    admission =
      with {:ok, buffer} <- admit(access_unit, state), :ok <- acquisition_budget(buffer, state), do: {:ok, buffer}

    case admission do
      {:ok, buffer} ->
        state = %{state | pending: ctx.from, last_dts: access_unit.dts}
        state = charge_acquisition(state, buffer)
        state = if state.timer == nil, do: arm_timer(state), else: state
        available = state.limits.max_buffered_bytes - state.buffered_bytes
        {[notify_child: {:source, {:push, buffer, available}}], state}

      {:error, reason} ->
        fail(reason, %{state | pending: ctx.from})
    end
  end

  def handle_call(:finish, ctx, %{waiting?: true} = state),
    do: fail(:initial_keyframe_missing, %{state | pending: ctx.from})

  def handle_call(:finish, ctx, %{buffered_samples: count} = state) when count < 2,
    do: fail(:insufficient_tail_samples, %{state | pending: ctx.from})

  def handle_call(:finish, ctx, state), do: {[notify_child: {:source, :finish}], %{state | pending: ctx.from}}

  @impl true
  def handle_child_notification({:error, reason}, _child, _ctx, state), do: fail(reason, state)

  def handle_child_notification(:waiting_for_keyframe, :admission, _ctx, %{error: nil, waiting?: true} = state) do
    {[reply_to: {state.pending, {:ok, []}}], %{state | pending: nil}}
  end

  def handle_child_notification({:complete, events, boundary}, :sink, _ctx, %{error: nil} = state) do
    fragments = for {:fragment, fragment} <- events, do: fragment
    released_bytes = Enum.sum(Enum.map(fragments, & &1.sample_bytes))
    released_samples = Enum.sum(Enum.map(fragments, & &1.sample_count))
    state = if boundary.keyframe?, do: arm_timer(state), else: state
    state = %{state | waiting?: false, acquisition_bytes: 0, acquisition_samples: 0, acquisition_start_ns: nil}
    actions = [reply_to: {state.pending, {:ok, with_clock(events, state.clock)}}]

    {actions,
     %{
       state
       | pending: nil,
         buffered_bytes: state.buffered_bytes + boundary.accepted_bytes - released_bytes,
         buffered_samples: state.buffered_samples + 1 - released_samples
     }}
  end

  def handle_child_notification({:finished, events}, :sink, _ctx, %{error: nil} = state) do
    cancel_timer(state)

    events =
      Enum.map(events, fn
        {:fragment, fragment} -> {:fragment, Map.put(fragment, :tail_duration_source, :previous_sample)}
        event -> event
      end)

    {[reply_to: {state.pending, {:ok, with_clock(events, state.clock)}}],
     %{state | pending: nil, finished?: true, timer: nil, timer_id: nil}}
  end

  def handle_child_notification(_notification, _child, _ctx, state), do: {[], state}

  @impl true
  def handle_info({:keyframe_timeout, id}, _ctx, %{timer_id: id, waiting?: true} = state),
    do: fail(:initial_keyframe_wait_exceeded, state)

  def handle_info({:keyframe_timeout, id}, _ctx, %{timer_id: id} = state), do: fail(:keyframe_wait_exceeded, state)
  def handle_info({:keyframe_timeout, _id}, _ctx, state), do: {[], state}

  def handle_info({:DOWN, ref, :process, _pid, _reason}, _ctx, %{owner_monitor: ref} = state),
    do: {[terminate: :normal], state}

  defp admit(%{payload: <<_byte, _rest::binary>> = payload, pts: pts, dts: dts}, state)
       when is_integer(pts) and is_integer(dts) and dts >= 0 do
    cond do
      byte_size(payload) > state.limits.max_access_unit_bytes ->
        {:error, :access_unit_too_large}

      pts != dts ->
        {:error, :frame_reordering_unsupported}

      state.last_dts != nil and dts <= state.last_dts ->
        {:error, :non_monotonic_timestamp}

      true ->
        timestamp = div(dts * Membrane.Time.second(), state.clock.timebase)

        if timestamp <= @max_timestamp_ns,
          do: {:ok, %Buffer{payload: payload, pts: timestamp, dts: timestamp}},
          else: {:error, :timestamp_out_of_range}
    end
  end

  defp admit(_access_unit, _state), do: {:error, :invalid_access_unit}

  defp acquisition_budget(_buffer, %{waiting?: false}), do: :ok

  defp acquisition_budget(buffer, state) do
    cond do
      state.acquisition_bytes + byte_size(buffer.payload) > state.limits.max_buffered_bytes ->
        {:error, :initial_acquisition_byte_limit}

      state.acquisition_samples >= state.limits.max_buffered_samples ->
        {:error, :initial_acquisition_sample_limit}

      state.acquisition_start_ns != nil and
          buffer.dts - state.acquisition_start_ns > state.limits.max_keyframe_interval_ns ->
        {:error, :initial_keyframe_interval_exceeded}

      true ->
        :ok
    end
  end

  defp charge_acquisition(%{waiting?: false} = state, _buffer), do: state

  defp charge_acquisition(state, buffer) do
    %{
      state
      | acquisition_bytes: state.acquisition_bytes + byte_size(buffer.payload),
        acquisition_samples: state.acquisition_samples + 1,
        acquisition_start_ns: state.acquisition_start_ns || buffer.dts
    }
  end

  defp fail(_reason, %{error: error} = state) when error != nil, do: {[], state}

  defp fail(reason, state) do
    cancel_timer(state)
    if state.pending == nil, do: send(state.owner, {__MODULE__, self(), {:error, reason}})
    replies = if state.pending, do: [reply_to: {state.pending, {:error, reason}}], else: []

    {replies ++ [remove_children: [:source, :parser, :admission, :muxer, :sink]],
     %{state | error: reason, pending: nil, timer: nil, timer_id: nil}}
  end

  defp arm_timer(state) do
    cancel_timer(state)
    id = make_ref()
    timer = Process.send_after(self(), {:keyframe_timeout, id}, state.limits.max_keyframe_wait_ms)
    %{state | timer: timer, timer_id: id}
  end

  defp cancel_timer(%{timer: nil}), do: :ok
  defp cancel_timer(%{timer: timer}), do: Process.cancel_timer(timer)
  defp with_clock(events, clock), do: Enum.map(events, fn {kind, event} -> {kind, Map.put(event, :clock, clock)} end)

  defp valid_clock?(
         %{clock_epoch: epoch, timebase: timebase, dts_source: :pts_no_reordering, utc_mapping: mapping} = clock
       )
       when map_size(clock) == 4 and is_integer(timebase) and timebase in 1..1_000_000_000 do
    valid_epoch?(epoch) and valid_mapping?(mapping, timebase) and byte_size(Jason.encode!(clock)) <= 1024
  end

  defp valid_clock?(_), do: false

  defp valid_epoch?(epoch) when is_binary(epoch) and byte_size(epoch) in 1..128,
    do: String.valid?(epoch) and String.printable?(epoch)

  defp valid_epoch?(_), do: false
  defp valid_mapping?(:unknown, _timebase), do: true

  defp valid_mapping?(
         %{origin_media_ticks: media, origin_utc_usec: utc, uncertainty_usec: uncertainty} = mapping,
         timebase
       )
       when map_size(mapping) == 3 and is_integer(media) and media >= 0 do
    signed_integer?(utc) and unsigned_integer?(uncertainty) and
      div(media * Membrane.Time.second(), timebase) <= @max_timestamp_ns
  end

  defp valid_mapping?(_, _timebase), do: false
  defp signed_integer?(value), do: is_integer(value) and value in -@max_timestamp_ns..@max_timestamp_ns
  defp unsigned_integer?(value), do: is_integer(value) and value in 0..@max_timestamp_ns
end
