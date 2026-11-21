defmodule ServiceRadarCoreElx.CameraRecording.NVRWorker do
  @moduledoc """
  Streams one bounded recording block from this node's camera relay to NVR ingest.

  Runs outside live-view and global relay control processes under
  `ServiceRadarCoreElx.CameraRecording.Supervisor`. Startup rechecks fenced
  ingest ownership, claims exclusive recorder ownership bound to the target NVR
  member's provisioned `storage_id`, reserves `block_sequence: 0`, attaches a
  bounded `ServiceRadarRecording.Inbox` to `CameraRelay.Pipeline`, and streams
  contiguous 90 kHz H264 AnnexB access units through `ServiceRadarNVRClient`
  once media arrives.

  Uncertain transport or timeout outcomes after network streaming starts stop
  production immediately without sending the clean wire EOF marker, never retry
  against the same or another replica, never bump `recorder_epoch`, and leave
  the reserved block and active recorder fence intact for operator inspection or
  recovery. A lost, cut-short or unreadable NVR answer is uncertain, and so is
  a non-200 answer read after the end marker, which can follow a seal.

  On a verified seal for its reserved block, the worker reads the canonical NVR
  descriptor and the camera's recording policy before calling
  `ServiceRadar.Camera.RecordingBlocks.freeze_and_catalog/6` under its live
  claim. Each step runs at most once. Registration leaves lease time for claim
  release and relay close. The first admitted unit anchors the run, identified
  by the clock epoch. Its anchor ID combines the epoch and block sequence.

  The worker attempts claim release and requests relay close before reporting a
  verified seal, including when registration was refused or its outcome is
  uncertain. See `ServiceRadarCoreElx.CameraRecording.NVRCapture` for the receipt
  fields.

  An NVR that answers 400, 401, 422 or 503 before the end marker was sent has
  refused the unfinished stream and sealed nothing it had open. That is a
  definite failure: the worker reports `{:nvr_ingest_refused, details}` with the
  status and correlation fields and attempts to release the recorder claim,
  as it does for a failure before streaming. The reservation stays `:open_local`
  and the NVR keeps the block's unsealed journal.

  Core can also stop the stream itself: a unit that fails order validation, a
  failed relay drain, a stopped relay pipeline or a failed fence renewal. The
  NVR client sends the end marker only after the sender has pulled `:eof`, so a
  Core abort before the worker hands out `:eof` cannot have requested a seal of
  the block the NVR had open. That is a definite failure too: the worker reports
  `{:nvr_ingest_aborted, details}` with the abort `reason` and the correlation
  fields and attempts to release the recorder claim. Without a verified receipt,
  a Core abort after `:eof` stays uncertain because the NVR may have sealed.
  Capture timeout and caller loss stay uncertain before `:eof` too. On
  an NVR whose block limit a capture can exceed, the NVR may already have
  rotated and sealed an earlier block of an aborted or refused capture. It keeps
  that block, but reports mid-stream seals only in a 200 receipt, so Core never
  learns its ID.

  `frames_sent` and `bytes_sent` count the units the sender pulled for the NVR
  client, not the units accepted from the relay. On a failure they are an upper
  bound on what reached the NVR.

  A capture stops at the first of its frame, byte and media-duration bounds
  (defaults 240 frames, 8 MiB, 6 s). The ceilings are 8,100 frames, 12 MiB and
  270 s: about 4.5 minutes at 30 fps. The byte ceiling stays below the NVR's
  16 MiB block, and with the NVR's default 150-fragment block limit and 2 s
  fragments a 270 s capture needs about 136 fragments, so a capture fits one
  NVR block. The receipt must name exactly that block; any other receipt is
  treated as uncertain. A 270 s capture needs a `timeout_ms` of about 295,000,
  within the 300,000 ms ceiling, and an NVR `SERVICERADAR_NVR_MAX_DURATION_MS`
  long enough to cover the request and its seal. The timeout must also leave
  time to register the block after the seal; a block sealed too close to the
  deadline is left to the reconciler.
  """

  use GenServer, restart: :temporary

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Camera.CameraRecordingPolicy
  alias ServiceRadar.Camera.IngestOwnership
  alias ServiceRadar.Camera.RecorderOwnership
  alias ServiceRadar.Camera.RecordingBlock
  alias ServiceRadar.Camera.RecordingBlocks
  alias ServiceRadar.Camera.RelaySessionManager
  alias ServiceRadarCoreElx.CameraRecording.RecorderRenewal
  alias ServiceRadarCoreElx.CameraRelay.PipelineManager
  alias ServiceRadarNVRClient.Config, as: ClientConfig
  alias ServiceRadarRecording.Inbox
  alias ServiceRadarRecordingControl.RecoveryGate

  require Logger

  @lease_ms 30_000
  @call_cap_ms 5_000
  @min_call_timeout_ms 250
  @max_capture_timeout_ms 300_000
  @inbox_defaults [max_samples: 128, max_bytes: 16_777_216]
  @default_bounds %{
    max_frames: 240,
    max_bytes: 8_388_608,
    max_duration_ms: 6_000
  }
  @max_frames_ceiling 8_100
  @max_bytes_ceiling 12_582_912
  @max_duration_ms_ceiling 270_000
  # The NVR ingest route refuses a stream with 400 (invalid header or request),
  # 401 (unauthorized), 422 (incomplete or rejected media) or 503 (unavailable).
  # Read before the end marker went out (`:ingest_refused`), each means the
  # block the NVR had open was never sealed: it seals the final block only after
  # the end marker, and keeps that block's journal. The same status after the
  # end marker (`:ingest_status`) can follow a seal, so it stays uncertain.
  @definite_refusals [400, 401, 422, 503]

  # Capture timeout and caller loss are interrupts the NVR ingest docs define as
  # uncertain, and they stay so even when Core stops the stream before `:eof`.
  # Making them definite is a separate product decision.
  @uncertain_interrupts [:capture_timeout, :capture_cancelled]

  def start_link(opts) do
    owner = Keyword.fetch!(opts, :owner)
    name = {:via, Registry, {ServiceRadarCoreElx.CameraRecording.Registry, {owner.id, owner.epoch}}}
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    owner = Keyword.fetch!(opts, :owner)
    media_ingest_id = Keyword.fetch!(opts, :media_ingest_id)
    member = Keyword.fetch!(opts, :member)
    storage_id = Keyword.fetch!(opts, :storage_id)
    %ClientConfig{} = client_config = Keyword.fetch!(opts, :client_config)

    with true <- ServiceRadarCoreElx.CameraRecording.Supervisor.enabled?() || {:error, :recording_disabled},
         {:ok, bounds} <- normalize_bounds(Keyword.get(opts, :bounds, %{})),
         {:ok, capture} <- build_capture(opts),
         {:ok, pipeline} <- PipelineManager.recording_pipeline(owner.relay_session_id, media_ingest_id) do
      state = %{
        owner: owner,
        media_ingest_id: media_ingest_id,
        member: member,
        storage_id: storage_id,
        client_config: client_config,
        bounds: bounds,
        capture: capture,
        pipeline: pipeline,
        pipeline_monitor: Process.monitor(pipeline),
        notify: Keyword.get(opts, :notify),
        inbox_opts: Keyword.merge(@inbox_defaults, Keyword.get(opts, :inbox_opts, [])),
        actor: SystemActor.system(:camera_recording),
        claim_token: Ecto.UUID.generate(),
        claim: nil,
        lease_deadline: nil,
        block: nil,
        recovery_gate: nil,
        wire_header: nil,
        inbox: nil,
        detached?: false,
        input_complete?: false,
        bound_reached?: false,
        drain_reason: nil,
        abort_reason: nil,
        eof_replied?: false,
        queue: :queue.new(),
        waiting_puller: nil,
        sender_pid: nil,
        sender_monitor: nil,
        sender_ref: nil,
        uncertain?: false,
        lease_timer: nil,
        first_pts: nil,
        first_admitted_at_us: nil,
        last_pts: nil,
        last_sequence: nil,
        frames_accepted: 0,
        bytes_accepted: 0,
        frames_sent: 0,
        bytes_sent: 0
      }

      {:ok, state, {:continue, :acquire_and_attach}}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_continue(:acquire_and_attach, state) do
    request_start = now()

    with {:ok, owner_opts} <- capture_call_opts(state),
         {:ok, gate} <- check_recovery_gate(),
         {:ok, owner} <- IngestOwnership.with_current_owner(state.owner, &{:ok, &1}, owner_opts),
         true <- is_binary(owner.relay_session_id) || {:error, :relay_unbound},
         {:ok, acquire_opts} <- capture_call_opts(state),
         {:ok, claim} <-
           RecorderOwnership.acquire(
             owner,
             state.claim_token,
             state.media_ingest_id,
             state.storage_id,
             @lease_ms,
             acquire_opts
           ) do
      lease_deadline = claim_lease_deadline(request_start, claim)
      state = %{state | owner: owner, claim: claim, lease_deadline: lease_deadline, recovery_gate: gate}
      open_and_attach(state, min(lease_deadline, state.capture.deadline))
    else
      {:error, reason} -> stop_failed(state, reason)
    end
  end

  @impl true
  def handle_call(:pull_unit, from, state) do
    cond do
      state.abort_reason != nil ->
        {:reply, {:abort, state.abort_reason}, state}

      not :queue.is_empty(state.queue) ->
        {{:value, unit}, rest} = :queue.out(state.queue)
        release_inbox_credit(state, byte_size(unit.payload))

        next = %{
          state
          | queue: rest,
            frames_sent: state.frames_sent + 1,
            bytes_sent: state.bytes_sent + byte_size(unit.payload)
        }

        {:reply, {:unit, unit}, next}

      state.input_complete? ->
        {reply, next} = eof_or_abort(state)
        {:reply, reply, next}

      state.waiting_puller == nil ->
        {:noreply, %{state | waiting_puller: from}}

      true ->
        {:reply, {:abort, :concurrent_pull_not_allowed}, state}
    end
  end

  @impl true
  def handle_cast({:interrupt, reason}, state), do: handle_interrupt(state, reason)

  @impl true
  def handle_info({:recording_media, id, unit}, %{inbox: %{id: id}} = state) do
    if state.bound_reached? or state.input_complete? or state.abort_reason != nil do
      release_inbox_credit(state, byte_size(unit.payload))
      {:noreply, state}
    else
      accept_media_unit(state, unit)
    end
  end

  def handle_info({:recording_end, id}, %{inbox: %{id: id}} = state) do
    if state.sender_pid == nil do
      stop_failed(%{state | detached?: true, input_complete?: true}, state.drain_reason || :no_recorded_media)
    else
      complete_input(state, drain_usable(state))
    end
  end

  def handle_info({:recording_rejected, id, reason}, %{inbox: %{id: id}} = state) do
    abort_stream(state, reason)
  end

  def handle_info({sender_ref, send_result}, %{sender_ref: sender_ref} = state) do
    finalize_send_result(state, send_result)
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{sender_monitor: ref} = state) do
    finalize_uncertain(state, state.abort_reason || {:sender_crashed, reason})
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{capture: %{monitor: ref}} = state) do
    handle_interrupt(state, :capture_cancelled)
  end

  def handle_info({:capture_deadline, ref}, %{capture: %{monitor: ref}} = state) do
    handle_interrupt(state, :capture_timeout)
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{pipeline_monitor: ref} = state) do
    abort_stream(%{state | detached?: true}, :ingest_stopped)
  end

  def handle_info(:renew_lease, %{abort_reason: reason} = state) when not is_nil(reason),
    do: {:noreply, %{state | lease_timer: nil}}

  def handle_info(:renew_lease, %{input_complete?: true, sender_pid: nil} = state),
    do: {:noreply, %{state | lease_timer: nil}}

  def handle_info(:renew_lease, state) do
    request_start = now()
    state = %{state | lease_timer: nil}

    # The held lease covers the rest of the capture, and this renewal's budget
    # could not outlast a normal checkout queue (see `RecorderRenewal`).
    if RecorderRenewal.skip?(request_start, state.capture.deadline, state.lease_deadline),
      do: {:noreply, state},
      else: renew_lease(state, request_start)
  end

  def handle_info({:EXIT, _from, reason}, state) when reason != :normal, do: handle_interrupt(state, reason)

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if state.inbox, do: Inbox.cancel(state.inbox)
    if state.lease_timer, do: Process.cancel_timer(state.lease_timer)
    if state.capture, do: Process.cancel_timer(state.capture.timer)

    if is_pid(state.sender_pid) and Process.alive?(state.sender_pid) do
      Process.exit(state.sender_pid, :kill)
    end

    if state.claim != nil and not state.uncertain? and state.sender_pid == nil do
      release_clean_consumer(state)
    end

    :ok
  end

  defp open_and_attach(state, deadline_ms) do
    retained_clock = %{
      "clock_epoch" => "#{state.owner.relay_session_id}:#{state.claim.recorder_epoch}",
      "timebase" => 90_000,
      "dts_source" => "pts_no_reordering",
      "utc_mapping" => "unknown"
    }

    with {:ok, inbox} <-
           Inbox.new(
             state.pipeline,
             state.owner.relay_session_id,
             state.media_ingest_id,
             deadline_ms,
             state.inbox_opts
           ),
         :ok <- Inbox.usable(inbox),
         {:ok, reserve_opts} <- capture_call_opts(state),
         {:ok, block} <- RecorderOwnership.reserve_block(state.owner, state.claim, retained_clock, reserve_opts),
         {:ok, header} <- build_wire_header(state.storage_id, state.recovery_gate.generation, block),
         {:ok, attach_timeout} <- capture_call_timeout(state.capture),
         :ok <- attach_pipeline(state.pipeline, inbox, attach_timeout) do
      next =
        state
        |> Map.merge(%{inbox: inbox, block: block, wire_header: header, drain_reason: nil})
        |> schedule_renewal()

      notify(next, {:attached, correlation_fields(next)})
      {:noreply, next}
    else
      {:error, reason} -> stop_failed(state, reason)
    end
  end

  defp build_wire_header(storage_id, recovery_generation, block) do
    identity =
      block
      |> RecordingBlock.identity()
      |> Map.delete("clock")

    {:ok,
     %{
       "version" => 1,
       "storage_id" => storage_id,
       "recovery_generation" => recovery_generation,
       "identity" => identity,
       "clock_epoch" => block.clock["clock_epoch"]
     }}
  end

  defp attach_pipeline(pipeline, inbox, timeout) do
    Membrane.Pipeline.call(pipeline, {:attach_recorder, inbox}, timeout)
  catch
    :exit, _reason -> {:error, :ingest_stopped}
  end

  defp renew_lease(state, request_start) do
    with {:ok, renew_opts} <- capture_call_opts(state),
         {:ok, _gate} <- check_recovery_gate(),
         {:ok, claim} <- RecorderOwnership.renew(state.owner, state.claim, @lease_ms, renew_opts),
         lease_deadline = claim_lease_deadline(request_start, claim),
         :ok <- renew_inbox(state.inbox, min(lease_deadline, state.capture.deadline)) do
      {:noreply, schedule_renewal(%{state | claim: claim, lease_deadline: lease_deadline})}
    else
      {:error, reason} -> renewal_failed(state, reason)
    end
  end

  defp renew_inbox(nil, _deadline_ms), do: :ok
  defp renew_inbox(inbox, deadline_ms), do: Inbox.renew(inbox, deadline_ms)

  defp renewal_failed(%{detached?: true} = state, :recording_stopped), do: {:noreply, state}
  defp renewal_failed(state, :recording_stopped), do: handle_administrative_stop(state)
  defp renewal_failed(%{sender_pid: nil} = state, :deadline_imminent), do: stop_failed(state, :capture_timeout)
  defp renewal_failed(state, :deadline_imminent), do: {:noreply, state}
  defp renewal_failed(state, reason), do: abort_stream(state, reason)

  defp ensure_sender_started(%{sender_pid: pid} = state) when is_pid(pid), do: {:ok, state}

  defp ensure_sender_started(state) do
    case state.capture.deadline - now() do
      remaining_ms when remaining_ms < @min_call_timeout_ms -> {:error, :capture_timeout}
      remaining_ms when remaining_ms > @max_capture_timeout_ms -> {:error, :invalid_capture_timeout}
      remaining_ms -> {:ok, spawn_sender(state, remaining_ms)}
    end
  end

  defp spawn_sender(state, timeout_ms) do
    worker = self()
    sender_ref = make_ref()
    client_config = state.client_config
    header = state.wire_header

    {sender_pid, sender_monitor} =
      spawn_monitor(fn ->
        stream = Stream.resource(fn -> worker end, &pull_from_worker/1, fn _ -> :ok end)
        result = ServiceRadarNVRClient.send_recording(client_config, header, stream, timeout_ms)
        send(worker, {sender_ref, result})
      end)

    next = %{state | sender_pid: sender_pid, sender_monitor: sender_monitor, sender_ref: sender_ref}
    notify(next, {:started, correlation_fields(next)})
    next
  end

  defp pull_from_worker(worker) do
    case GenServer.call(worker, :pull_unit, :infinity) do
      {:unit, unit} -> {[unit], worker}
      :eof -> {:halt, worker}
      {:abort, reason} -> throw({:nvr_producer_aborted, reason})
    end
  end

  defp accept_media_unit(state, unit) do
    with :ok <- check_capture(state.capture),
         :ok <- Inbox.usable(state.inbox),
         :ok <- validate_unit_order(state, unit) do
      apply_unit_bounds(state, unit)
    else
      {:error, reason} ->
        release_inbox_credit(state, byte_size(unit.payload))
        abort_stream(state, reason)
    end
  end

  defp validate_unit_order(state, unit) do
    cond do
      unit.dts != unit.pts ->
        {:error, :reordered_dts}

      state.last_sequence != nil and unit.sequence != state.last_sequence + 1 ->
        {:error, :media_sequence_discontinuity}

      state.last_pts != nil and unit.pts < state.last_pts ->
        {:error, :non_monotonic_timestamp}

      true ->
        :ok
    end
  end

  defp apply_unit_bounds(state, unit) do
    unit_bytes = byte_size(unit.payload)
    next_bytes = state.bytes_accepted + unit_bytes

    if next_bytes > state.bounds.max_bytes do
      release_inbox_credit(state, unit_bytes)

      if state.frames_accepted == 0 do
        abort_stream(state, :frame_exceeds_max_bytes)
      else
        next = state |> Map.put(:bound_reached?, true) |> detach_recorder() |> maybe_reply_puller()
        {:noreply, next}
      end
    else
      first_pts = state.first_pts || unit.pts
      first_admitted_at_us = state.first_admitted_at_us || unit.admitted_at_us
      next_frames = state.frames_accepted + 1
      duration_ticks = unit.pts - first_pts
      max_duration_ticks = div(state.bounds.max_duration_ms * 90_000, 1_000)
      reached_bound? = next_frames >= state.bounds.max_frames or duration_ticks >= max_duration_ticks

      next = %{
        state
        | queue: :queue.in(unit, state.queue),
          first_pts: first_pts,
          first_admitted_at_us: first_admitted_at_us,
          last_pts: unit.pts,
          last_sequence: unit.sequence,
          frames_accepted: next_frames,
          bytes_accepted: next_bytes
      }

      send_queued_unit(next, reached_bound?)
    end
  end

  defp send_queued_unit(state, reached_bound?) do
    case ensure_sender_started(state) do
      {:ok, next} ->
        next = if reached_bound?, do: detach_recorder(%{next | bound_reached?: true}), else: next
        {:noreply, maybe_reply_puller(next)}

      {:error, reason} ->
        abort_stream(state, reason)
    end
  end

  defp maybe_reply_puller(%{waiting_puller: nil} = state), do: state

  defp maybe_reply_puller(%{waiting_puller: from} = state) do
    cond do
      state.abort_reason != nil ->
        GenServer.reply(from, {:abort, state.abort_reason})
        %{state | waiting_puller: nil}

      not :queue.is_empty(state.queue) ->
        {{:value, unit}, rest} = :queue.out(state.queue)
        release_inbox_credit(state, byte_size(unit.payload))
        GenServer.reply(from, {:unit, unit})

        %{
          state
          | queue: rest,
            waiting_puller: nil,
            frames_sent: state.frames_sent + 1,
            bytes_sent: state.bytes_sent + byte_size(unit.payload)
        }

      state.input_complete? ->
        {reply, next} = eof_or_abort(state)
        GenServer.reply(from, reply)
        %{next | waiting_puller: nil}

      true ->
        state
    end
  end

  defp handle_administrative_stop(state) do
    if state.frames_accepted > 0 do
      next = state |> Map.put(:drain_reason, :recording_stopped) |> detach_recorder() |> maybe_reply_puller()
      {:noreply, next}
    else
      abort_stream(state, :recording_stopped)
    end
  end

  defp detach_recorder(%{detached?: true} = state), do: state

  defp detach_recorder(state) do
    state = %{state | detached?: true}
    if state.inbox, do: drain_or_cancel_inbox(state), else: %{state | input_complete?: true}
  end

  defp drain_or_cancel_inbox(state) do
    with :ok <- drain_usable(state),
         :ok <- drain_inbox(state, drain_timeout(state)),
         :ok <- drain_usable(state) do
      state
    else
      {:error, reason} -> fail_drain(state, reason)
    end
  end

  defp drain_timeout(state) do
    min(@call_cap_ms, max(1, min(Inbox.remaining_ms(state.inbox), state.capture.deadline - now())))
  end

  defp drain_inbox(state, timeout) do
    case Membrane.Pipeline.call(state.pipeline, {:drain_recorder, state.inbox.id}, timeout) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
      _other -> {:error, :recording_drain_failed}
    end
  catch
    :exit, _ -> {:error, :recording_drain_failed}
  end

  defp fail_drain(state, reason) do
    resolved = resolve_drain_abort_reason(state, reason)
    Inbox.cancel(state.inbox)
    state = cancel_lease_timer(state)
    %{state | input_complete?: true, abort_reason: state.abort_reason || resolved}
  end

  defp resolve_drain_abort_reason(state, reason) do
    case drain_usable(state) do
      {:error, usable_reason} when usable_reason != :recording_closed -> usable_reason
      _ -> reason
    end
  end

  defp drain_usable(state) do
    with :ok <- check_capture(state.capture) do
      if state.inbox, do: Inbox.usable(state.inbox), else: :ok
    end
  end

  defp complete_input(state, :ok) do
    next =
      state
      |> Map.merge(%{detached?: true, input_complete?: true})
      |> maybe_reply_puller()

    {:noreply, next}
  end

  defp complete_input(state, {:error, reason}), do: abort_stream(state, reason)

  defp eof_or_abort(state) do
    case drain_usable(state) do
      :ok ->
        {:eof, %{state | eof_replied?: true}}

      {:error, reason} ->
        abort = state.abort_reason || reason
        {{:abort, abort}, %{state | abort_reason: abort}}
    end
  end

  defp abort_stream(state, reason) do
    if state.inbox, do: Inbox.cancel(state.inbox)
    state = cancel_lease_timer(state)

    next =
      maybe_reply_puller(%{state | abort_reason: state.abort_reason || reason, detached?: true, input_complete?: true})

    if next.sender_pid == nil do
      stop_failed(next, next.abort_reason)
    else
      {:noreply, next}
    end
  end

  defp handle_interrupt(state, reason) do
    if state.sender_pid == nil do
      stop_failed(state, reason)
    else
      Process.exit(state.sender_pid, :kill)
      {:noreply, %{state | abort_reason: state.abort_reason || reason}}
    end
  end

  defp finalize_send_result(state, send_result) do
    if state.sender_monitor, do: Process.demonitor(state.sender_monitor, [:flush])
    state = cancel_lease_timer(%{state | sender_pid: nil, sender_monitor: nil})
    block_key = state.block.block_key
    storage_id = state.storage_id

    refusal_reason = state.abort_reason || capture_error(check_capture(state.capture))
    eof_replied? = state.eof_replied?

    case {send_result, refusal_reason, check_recovery_gate()} do
      {{:ok, %{status: :sealed_local, storage_id: ^storage_id, block_ids: [^block_key]}}, reason, gate_status} ->
        catalog = register_sealed_block(state, reason, gate_status)
        release = release_clean_consumer(state)
        payload = Map.merge(correlation_fields(state), %{status: :sealed_local, catalog: catalog, release: release})
        notify(state, {:completed, payload})
        {:stop, :normal, %{state | claim: nil}}

      {{:error, {:ingest_refused, status}}, nil, {:ok, _gate}} when status in @definite_refusals ->
        refusal =
          state
          |> correlation_fields()
          |> Map.put(:status, status)

        stop_failed(state, {:nvr_ingest_refused, refusal})

      # Core stopped the stream before the sender pulled `:eof`, so the client
      # never sent the end marker and the NVR sealed nothing it had open,
      # whatever the client returned.
      {_result, abort_reason, {:ok, _gate}}
      when not is_nil(abort_reason) and abort_reason not in @uncertain_interrupts and not eof_replied? ->
        abort =
          state
          |> correlation_fields()
          |> Map.put(:reason, abort_reason)

        stop_failed(state, {:nvr_ingest_aborted, abort})

      {other_result, reason, _gate_status} ->
        reason = classify_send_failure(reason, state.frames_sent, other_result)
        finalize_uncertain(state, reason)
    end
  end

  defp register_sealed_block(state, refusal_reason, gate_status) do
    outcome = if refusal_reason, do: {:unregistered, refusal_reason}, else: run_registration(state, gate_status)

    if !match?({:registered, _}, outcome) do
      Logger.warning("NVR block #{state.block.block_key} registration: #{inspect(outcome, limit: 8)}")
    end

    outcome
  end

  defp run_registration(_state, {:error, reason}), do: {:unregistered, reason}

  defp run_registration(state, {:ok, _gate}) do
    lease_limit = state.lease_deadline - RecorderRenewal.teardown_ms()
    deadline = min(lease_limit, state.capture.deadline)
    now = now()

    cond do
      lease_limit - now < @min_call_timeout_ms ->
        {:unregistered, :registration_cleanup_reserve}

      deadline - now < @min_call_timeout_ms ->
        {:unregistered, :registration_deadline}

      true ->
        catalog_before_deadline(state, deadline)
    end
  end

  defp catalog_before_deadline(state, deadline) do
    case run_until(deadline, fn -> catalog_sealed_block(state, deadline) end) do
      {:ok, result} -> result
      {:exit, reason} -> {:unconfirmed, reason}
    end
  end

  defp catalog_sealed_block(state, deadline) do
    with {:ok, read_timeout} <- step_timeout(deadline, ServiceRadarNVRClient.descriptor_timeout_ms()),
         {:ok, descriptor} <-
           ServiceRadarNVRClient.block_descriptor(state.client_config, state.block.block_key, read_timeout),
         {:ok, policy_timeout} <- step_timeout(deadline, @call_cap_ms),
         {:ok, policy} <-
           CameraRecordingPolicy.get_by_camera_profile(state.owner.camera_source_id, state.owner.stream_profile_id,
             actor: state.actor,
             timeout: policy_timeout,
             not_found_error?: false
           ),
         {:ok, freeze_timeout} <- step_timeout(deadline, @call_cap_ms) do
      state.owner
      |> RecordingBlocks.freeze_and_catalog(state.claim, state.block, descriptor, catalog_attrs(state, policy),
        actor: state.actor,
        timeout: freeze_timeout
      )
      |> freeze_outcome()
    else
      {:error, reason} -> {:unregistered, reason}
    end
  end

  defp step_timeout(deadline, cap) do
    remaining = deadline - now()
    if remaining < @min_call_timeout_ms, do: {:error, :registration_deadline}, else: {:ok, min(remaining, cap)}
  end

  defp freeze_outcome({:ok, entry}), do: {:registered, entry.id}

  defp freeze_outcome({:error, reason})
       when reason in [
              :ambient_transaction,
              :nvr_recovery_closed,
              :invalid_recording_descriptor,
              :invalid_catalog_attributes,
              :recording_descriptor_conflict,
              :recording_block_mismatch,
              :recording_block_not_found,
              :ownership_lost,
              :recorder_claim_lost,
              :recorder_ingest_mismatch,
              :owner_unavailable
            ], do: {:unregistered, reason}

  defp freeze_outcome({:error, %Ash.Error.Invalid{errors: errors} = reason}) do
    if Enum.all?(errors, &validation_error?/1), do: {:unregistered, reason}, else: {:unconfirmed, reason}
  end

  defp freeze_outcome({:error, %Ash.Error.Forbidden{} = reason}), do: {:unregistered, reason}
  defp freeze_outcome({:error, reason}), do: {:unconfirmed, reason}

  defp validation_error?(%Ash.Error.Invalid.Timeout{}), do: false
  defp validation_error?(error), do: match?(%{class: :invalid}, error)

  defp run_until(deadline, operation) do
    task = Task.async(operation)

    case Task.yield(task, max(0, deadline - now())) do
      nil ->
        Task.shutdown(task, :brutal_kill)
        {:exit, :timeout}

      reply ->
        if now() < deadline, do: reply, else: {:exit, :timeout}
    end
  end

  # One capture is one run, anchored at its first admitted unit.
  defp catalog_attrs(state, policy) do
    clock_epoch = state.block.clock["clock_epoch"]

    Map.merge(
      %{
        time_basis: :received,
        first_unit_pts: state.first_pts,
        first_unit_received_at: DateTime.from_unix!(state.first_admitted_at_us, :microsecond),
        run_id: clock_epoch,
        anchor_id: "#{clock_epoch}:#{state.block.block_sequence}"
      },
      policy_attrs(policy)
    )
  end

  defp policy_attrs(%CameraRecordingPolicy{id: id, storage: storage}), do: %{policy_id: id, policy_storage: storage}
  defp policy_attrs(nil), do: %{policy_storage: :local_only}

  defp capture_error(:ok), do: nil
  defp capture_error({:error, reason}), do: reason

  defp classify_send_failure(abort_reason, _frames_sent, _result) when not is_nil(abort_reason), do: abort_reason
  defp classify_send_failure(nil, 0, {:error, reason}), do: {:no_media_sealed, reason}
  defp classify_send_failure(nil, _frames_sent, {:error, reason}), do: reason
  defp classify_send_failure(nil, _frames_sent, {:ok, receipt}), do: {:unexpected_nvr_receipt, receipt}

  defp finalize_uncertain(state, reason) do
    if state.inbox, do: Inbox.cancel(state.inbox)
    state = cancel_lease_timer(state)

    payload =
      state
      |> correlation_fields()
      |> Map.put(:reason, reason)

    next = %{state | sender_pid: nil, sender_monitor: nil, uncertain?: true}
    notify(next, {:uncertain, payload})
    {:stop, :normal, next}
  end

  defp stop_failed(state, :deadline_imminent), do: stop_failed(state, :capture_timeout)

  defp stop_failed(state, reason) do
    if state.inbox, do: Inbox.cancel(state.inbox)
    notify(state, {:failed, %{reason: reason}})
    {:stop, :normal, state}
  end

  defp correlation_fields(state) do
    %{
      recording_block_id: state.block && state.block.id,
      block_key: state.block && state.block.block_key,
      storage_id: state.storage_id,
      member: state.member,
      recorder_epoch: state.claim && state.claim.recorder_epoch,
      relay_session_id: state.owner.relay_session_id,
      frames_sent: state.frames_sent,
      bytes_sent: state.bytes_sent
    }
  end

  defp release_inbox_credit(%{detached?: false, inbox: %Inbox{} = inbox}, bytes) do
    _ = Inbox.release(inbox, bytes)
    :ok
  end

  defp release_inbox_credit(_state, _bytes), do: :ok

  defp release_clean_consumer(state) do
    outcome = release_claim(state)
    request_relay_close(state.owner.relay_session_id, state.actor)
    outcome
  end

  defp release_claim(state) do
    timeout = RecorderRenewal.cleanup_timeout_ms()

    case run_until(now() + timeout, fn ->
           RecorderOwnership.release(state.owner, state.claim, actor: state.actor, timeout: timeout)
         end) do
      {:ok, {:ok, :released}} -> :released
      {:ok, {:error, reason}} -> release_pending(state, reason)
      {:exit, reason} -> release_pending(state, reason)
    end
  end

  defp release_pending(state, reason) do
    Logger.warning("Recorder claim #{state.claim.id} release pending lease expiry: #{inspect(reason, limit: 8)}")
    {:release_pending_lease_expiry, reason}
  end

  defp request_relay_close(relay_session_id, actor) do
    {_pid, ref} =
      spawn_monitor(fn ->
        RelaySessionManager.request_close(relay_session_id, reason: "recorder detached", actor: actor)
      end)

    receive do
      {:DOWN, ^ref, :process, _pid, _reason} -> :ok
    after
      RecorderRenewal.cleanup_timeout_ms() -> Process.demonitor(ref, [:flush])
    end

    :ok
  end

  defp normalize_bounds(overrides) when is_map(overrides) do
    merged = Map.merge(@default_bounds, overrides)

    if valid_int?(merged.max_frames, 1, @max_frames_ceiling) and
         valid_int?(merged.max_bytes, 1, @max_bytes_ceiling) and
         valid_int?(merged.max_duration_ms, 100, @max_duration_ms_ceiling) do
      {:ok, merged}
    else
      {:error, :invalid_capture_bounds}
    end
  end

  defp normalize_bounds(_overrides), do: {:error, :invalid_capture_bounds}

  defp valid_int?(value, min_val, max_val), do: is_integer(value) and value >= min_val and value <= max_val

  defp build_capture(opts) do
    caller = Keyword.get(opts, :caller)

    with true <- is_pid(caller) || {:error, :invalid_capture},
         {:ok, deadline} <- resolve_deadline(opts) do
      capture = %{caller: caller, deadline: deadline, monitor: Process.monitor(caller)}
      start_capture_timer(capture, check_capture(capture))
    end
  end

  defp resolve_deadline(opts) do
    case {Keyword.get(opts, :deadline), Keyword.get(opts, :timeout_ms, 25_000)} do
      {deadline, _} when is_integer(deadline) -> bounded_deadline(deadline)
      {nil, timeout_ms} when timeout_ms in 1..@max_capture_timeout_ms -> {:ok, now() + timeout_ms}
      _ -> {:error, :invalid_capture_timeout}
    end
  end

  defp bounded_deadline(deadline) do
    if deadline - now() > @max_capture_timeout_ms, do: {:error, :invalid_capture_timeout}, else: {:ok, deadline}
  end

  defp start_capture_timer(capture, :ok) do
    timer = Process.send_after(self(), {:capture_deadline, capture.monitor}, max(0, capture.deadline - now()))
    {:ok, Map.put(capture, :timer, timer)}
  end

  defp start_capture_timer(capture, {:error, _reason} = error) do
    Process.demonitor(capture.monitor, [:flush])
    error
  end

  defp capture_call_opts(state) do
    with {:ok, timeout} <- capture_call_timeout(state.capture) do
      {:ok, [actor: state.actor, timeout: timeout]}
    end
  end

  defp capture_call_timeout(capture) do
    with :ok <- check_capture(capture) do
      remaining_ms = capture.deadline - now()

      if remaining_ms < @min_call_timeout_ms,
        do: {:error, :deadline_imminent},
        else: {:ok, min(@call_cap_ms, remaining_ms)}
    end
  end

  defp check_capture(%{deadline: deadline} = capture) do
    if deadline <= now(), do: {:error, :capture_timeout}, else: check_caller_down(capture)
  end

  defp check_caller_down(%{caller: caller, monitor: monitor}) do
    receive do
      {:DOWN, ^monitor, :process, _pid, _reason} -> {:error, :capture_cancelled}
    after
      0 -> local_caller_status(caller)
    end
  end

  defp local_caller_status(caller) when node(caller) == node() do
    if Process.alive?(caller), do: :ok, else: {:error, :capture_cancelled}
  end

  defp local_caller_status(_remote_caller), do: :ok

  defp check_recovery_gate do
    gate = Application.get_env(:serviceradar_core, :nvr_recovery_gate)

    case RecoveryGate.check(gate) do
      :ok -> {:ok, gate}
      {:error, _} = error -> error
    end
  end

  defp claim_lease_deadline(request_start, claim),
    do: request_start + max(0, DateTime.diff(claim.lease_expires_at, claim.database_now, :millisecond))

  defp schedule_renewal(state) do
    state = cancel_lease_timer(state)
    delay = min(5_000, max(1, div(Inbox.remaining_ms(state.inbox), 2)))
    %{state | lease_timer: Process.send_after(self(), :renew_lease, delay)}
  end

  defp cancel_lease_timer(%{lease_timer: nil} = state), do: state

  defp cancel_lease_timer(state) do
    Process.cancel_timer(state.lease_timer)
    %{state | lease_timer: nil}
  end

  defp notify(%{notify: pid}, event) when is_pid(pid), do: send(pid, {:camera_nvr_capture, self(), event})
  defp notify(_state, _event), do: :ok

  defp now, do: System.monotonic_time(:millisecond)
end
