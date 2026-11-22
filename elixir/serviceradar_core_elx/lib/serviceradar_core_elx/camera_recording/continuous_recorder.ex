defmodule ServiceRadarCoreElx.CameraRecording.ContinuousRecorder do
  @moduledoc """
  Continuous relay-to-NVR block recorder for a single `(camera_source_id, stream_profile_id)`
  policy (`A.3.1`–`A.3.5`, design sections `A2`, `A3`, `A4`, `A7`, `T`).

  Runs under `ServiceRadarCoreElx.CameraRecording.Supervisor` on the node hosting
  the camera relay pipeline:

  1. Opens or reuses the shared relay (`RelaySessionManager.request_open/3`) and
     acquires one `RecorderOwnership` claim (with its `:recorder` consumer lease
     so the relay stays open with no viewers) renewed for the entire run.
  2. Attaches one bounded `ServiceRadarRecording.Inbox` for the run and buffers
     incoming access units across block handovers in a bounded handover queue.
  3. Loops one NVR ingest request per reserved block:
     - Soft bounds (`260_000 ms`, `7_800` frames, `10 MiB`) trigger a
       keyframe-aligned cut at the next IDR access unit (AnnexB NAL type 5 or
       `:keyframe` flag), starting block `N+1` with that IDR contiguously.
     - Hard ceilings (`270_000 ms`, `8_100` frames, `12 MiB`, matching `A.1.1`)
       cut immediately; non-IDR units until the next IDR are dropped and
       recorded as a `:keyframe_wait` `RecordingGap`.
     - Handover buffer overflow drops excess units without wedging the inbox and
       records an exact `:handover_overflow` `RecordingGap` by relay sequence
       and 90 kHz PTS.
  4. Resolves uncertain ingest outcomes via `ServiceRadarNVRClient.lookup_blocks/3`
     under the live claim (design `A3` table):
     - `:sealed` -> fetch descriptor, freeze/catalog, enqueue archive, continue.
     - `:absent` -> record `:block_absent` gap, continue with next sequence.
     - `:incomplete` / `:unresolved` -> record `:run_stopped` gap, end run for
       reconciler recovery.
     - member unreachable -> retry lookup within a bounded window, then record
       `:run_stopped` gap and end run leaving the claim for lease expiry.
  5. Checks wall-clock receipt time against the run's PTS-anchored estimate
     (`anchor_utc + (pts - anchor_pts) / 90_000`, design `T`) on each block and
     re-anchors (`reanchored: true`, new `anchor_id`) when drift exceeds 2 s or
     after a timestamp discontinuity.
  6. Best-effort enqueues `ArchiveBlockJob.enqueue_for_entry/2` after every
     sealed and cataloged block.
  """

  use GenServer, restart: :temporary

  import Bitwise

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Camera.IngestOwnership
  alias ServiceRadar.Camera.RecorderOwnership
  alias ServiceRadar.Camera.RecordingBlock
  alias ServiceRadar.Camera.RecordingBlocks
  alias ServiceRadar.Camera.RecordingGap
  alias ServiceRadar.Camera.RelaySession
  alias ServiceRadar.Camera.RelaySessionManager
  alias ServiceRadarCoreElx.CameraRecording.ArchiveBlockJob
  alias ServiceRadarCoreElx.CameraRecording.NVRTargetConfig
  alias ServiceRadarCoreElx.CameraRecording.RecorderRenewal
  alias ServiceRadarCoreElx.CameraRecording.Supervisor, as: RecordingSupervisor
  alias ServiceRadarCoreElx.CameraRelay.PipelineManager
  alias ServiceRadarRecording.Inbox
  alias ServiceRadarRecordingControl.RecoveryGate

  require Logger

  @timebase 90_000
  @lease_ms 30_000
  @call_cap_ms 5_000
  @block_send_timeout_ceiling_ms 300_000
  @seal_headroom_ms 30_000
  @default_drift_threshold_us 2_000_000
  @default_frame_duration_ticks 3_000
  @default_lookup_attempts 3
  @default_lookup_retry_delay_ms 1_000
  @default_lookup_timeout_ms 15_000
  @relay_poll_interval_ms 100
  @relay_open_timeout_ms 15_000

  @inbox_defaults [max_samples: 128, max_bytes: 16_777_216]

  @default_bounds %{
    soft_frames: 7_800,
    max_frames: 8_100,
    soft_bytes: 10_485_760,
    max_bytes: 12_582_912,
    soft_duration_ms: 260_000,
    max_duration_ms: 270_000
  }

  @max_frames_ceiling 8_100
  @max_bytes_ceiling 12_582_912
  @max_duration_ms_ceiling 270_000

  @definite_refusals [400, 401, 422, 503]

  @doc "Default soft and hard block bounds (`A.1.1`, `A.3.4`, design `A4`)."
  @spec default_bounds() :: map()
  def default_bounds, do: @default_bounds

  @doc "Registry key for a continuous recorder on this node."
  @spec registry_key(String.t(), String.t()) :: {:continuous, String.t(), String.t()}
  def registry_key(camera_source_id, stream_profile_id), do: {:continuous, camera_source_id, stream_profile_id}

  @doc "Starts a `ContinuousRecorder` linked to the caller or supervisor."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    case Keyword.fetch(opts, :name) do
      {:ok, nil} ->
        GenServer.start_link(__MODULE__, opts)

      {:ok, name} ->
        GenServer.start_link(__MODULE__, opts, name: name)

      :error ->
        policy = Keyword.fetch!(opts, :policy)
        key = registry_key(policy.camera_source_id, policy.stream_profile_id)
        name = {:via, Registry, {ServiceRadarCoreElx.CameraRecording.Registry, key}}

        GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @doc "Requests a graceful stop: finishes/seals any open block, releases claim, and exits."
  @spec stop(GenServer.server(), atom()) :: :ok
  def stop(server, reason \\ :policy_disabled), do: GenServer.cast(server, {:stop_recording, reason})

  @doc "Notifies a running recorder of an updated `CameraRecordingPolicy`."
  @spec update_policy(GenServer.server(), map()) :: :ok
  def update_policy(server, policy), do: GenServer.cast(server, {:update_policy, policy})

  @doc "Returns a snapshot of the recorder's run status (useful for diagnostics and tests)."
  @spec status(GenServer.server()) :: map()
  def status(server), do: GenServer.call(server, :status)

  @doc """
  Returns true when an access unit carries an H.264 IDR frame, detected from
  the relay's `:keyframe` flag when present or AnnexB NAL unit type 5 (`design.md` `A4`).
  """
  @spec keyframe_unit?(map()) :: boolean()
  def keyframe_unit?(%{keyframe: true}), do: true
  def keyframe_unit?(%{payload: payload}) when is_binary(payload), do: annexb_contains_idr?(payload)
  def keyframe_unit?(_unit), do: false

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    hooks = build_hooks(opts)

    with {:ok, policy} <- validate_policy(Keyword.get(opts, :policy)),
         true <- hooks.enabled_fn.() || {:error, :recording_disabled},
         {:ok, bounds} <- normalize_bounds(Keyword.get(opts, :bounds, %{})) do
      inbox_opts = Keyword.merge(@inbox_defaults, Keyword.get(opts, :inbox_opts, []))
      handover_max_samples = Keyword.get(opts, :handover_max_samples, Keyword.fetch!(inbox_opts, :max_samples))
      handover_max_bytes = Keyword.get(opts, :handover_max_bytes, Keyword.fetch!(inbox_opts, :max_bytes))

      state = %{
        policy: policy,
        bounds: bounds,
        hooks: hooks,
        actor: Keyword.get_lazy(opts, :actor, fn -> SystemActor.system(:camera_recording) end),
        notify: Keyword.get(opts, :notify),
        inbox_opts: inbox_opts,
        handover_max_samples: handover_max_samples,
        handover_max_bytes: handover_max_bytes,
        drift_threshold_us: Keyword.get(opts, :drift_threshold_us, @default_drift_threshold_us),
        lookup_max_attempts: Keyword.get(opts, :lookup_max_attempts, @default_lookup_attempts),
        lookup_retry_delay_ms: Keyword.get(opts, :lookup_retry_delay_ms, @default_lookup_retry_delay_ms),
        lookup_timeout_ms: Keyword.get(opts, :lookup_timeout_ms, @default_lookup_timeout_ms),
        send_timeout_ms: Keyword.get(opts, :send_timeout_ms, block_send_timeout_ms(bounds)),
        lease_ms: Keyword.get(opts, :lease_ms, @lease_ms),
        member: policy.nvr_member,
        storage_id: nil,
        client_config: nil,
        recovery_gate: nil,
        relay_session_id: nil,
        relay_origin: nil,
        media_ingest_id: nil,
        owner: nil,
        claim_token: Ecto.UUID.generate(),
        claim: nil,
        lease_deadline: nil,
        lease_timer: nil,
        run_id: nil,
        pipeline: nil,
        pipeline_monitor: nil,
        inbox: nil,
        detached?: false,
        stopping?: false,
        stop_reason: nil,
        keep_claim_on_exit?: false,
        # Intake & handover queue
        handover_queue: :queue.new(),
        handover_samples: 0,
        handover_bytes: 0,
        awaiting_keyframe?: false,
        last_admitted_sequence: nil,
        last_admitted_pts: nil,
        last_admitted_at_us: nil,
        last_unit_duration_ticks: @default_frame_duration_ticks,
        pending_gap: nil,
        # Anchor / time-basis state (design T)
        anchor_id: nil,
        anchor_pts: nil,
        anchor_utc_us: nil,
        # Previous completed block tracking
        prev_block_last_sequence: nil,
        prev_block_last_pts: nil,
        next_contiguous?: false,
        blocks_sealed: 0,
        gaps_recorded: 0,
        # Active block state
        phase: :starting,
        active_block: nil,
        waiting_puller: nil
      }

      {:ok, state, {:continue, :start_run}}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_continue(:start_run, state) do
    case establish_run(state) do
      {:ok, ready_state} ->
        notify(ready_state, {:run_started, run_summary(ready_state)})
        {:noreply, ready_state}

      {:error, reason, failed_state} ->
        maybe_record_startup_gap(failed_state, reason)
        notify(failed_state, {:run_stopped, %{reason: reason, run_id: failed_state.run_id}})
        {:stop, :normal, failed_state}
    end
  end

  @impl true
  def handle_call(:status, _from, state) do
    reply = %{
      phase: state.phase,
      run_id: state.run_id,
      member: state.member,
      storage_id: state.storage_id,
      policy_id: state.policy.id,
      policy_storage: state.policy.storage,
      blocks_sealed: state.blocks_sealed,
      gaps_recorded: state.gaps_recorded,
      anchor_id: state.anchor_id,
      stopping?: state.stopping?,
      handover_samples: state.handover_samples
    }

    {:reply, reply, state}
  end

  def handle_call(:pull_unit, from, %{active_block: nil} = state) do
    {:reply, {:abort, :no_active_block}, %{state | waiting_puller: clear_puller(state.waiting_puller, from)}}
  end

  def handle_call(:pull_unit, from, %{active_block: block} = state) do
    cond do
      block.abort_reason != nil ->
        {:reply, {:abort, block.abort_reason}, state}

      not :queue.is_empty(block.queue) ->
        {{:value, unit}, rest} = :queue.out(block.queue)
        release_inbox_credit(state, byte_size(unit.payload))

        next_block = %{
          block
          | queue: rest,
            frames_sent: block.frames_sent + 1,
            bytes_sent: block.bytes_sent + byte_size(unit.payload)
        }

        {:reply, {:unit, unit}, %{state | active_block: next_block}}

      block.input_complete? ->
        next_block = %{block | eof_replied?: true}
        {:reply, :eof, %{state | active_block: next_block}}

      state.waiting_puller == nil ->
        {:noreply, %{state | waiting_puller: from}}

      true ->
        {:reply, {:abort, :concurrent_pull_not_allowed}, state}
    end
  end

  @impl true
  def handle_cast({:stop_recording, reason}, state) do
    handle_graceful_stop(state, reason)
  end

  def handle_cast({:update_policy, new_policy}, state) do
    cond do
      new_policy.mode != :continuous ->
        handle_graceful_stop(state, :policy_disabled)

      new_policy.nvr_member != state.policy.nvr_member ->
        handle_graceful_stop(state, :member_changed)

      true ->
        {:noreply, %{state | policy: new_policy}}
    end
  end

  @impl true
  def handle_info({:recording_media, id, unit}, %{inbox: %{id: id}} = state) do
    if state.stopping? do
      release_inbox_credit(state, byte_size(unit.payload))
      {:noreply, state}
    else
      handle_incoming_unit(state, unit)
    end
  end

  def handle_info({:recording_end, id}, %{inbox: %{id: id}} = state) do
    handle_relay_ended(state, :source_unavailable, "relay_closed")
  end

  def handle_info({:recording_rejected, id, :queue_full}, %{inbox: %{id: id}} = state) do
    state = record_immediate_gap(state, :handover_overflow, "inbox_queue_full")
    handle_fatal_run_stop(%{state | detached?: true}, :inbox_overflow)
  end

  def handle_info({:recording_rejected, id, reason}, %{inbox: %{id: id}} = state) do
    state = record_immediate_gap(state, :run_stopped, sanitize_detail_class(reason, "inbox_rejected"))
    handle_fatal_run_stop(%{state | detached?: true}, reason)
  end

  def handle_info({sender_ref, send_result}, %{active_block: %{sender_ref: sender_ref}} = state) do
    handle_sender_result(state, send_result)
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{active_block: %{sender_monitor: ref}} = state) do
    handle_sender_result(state, {:error, {:sender_crashed, reason}})
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{pipeline_monitor: ref} = state) do
    handle_relay_ended(%{state | detached?: true}, :source_unavailable, "pipeline_stopped")
  end

  def handle_info(:renew_lease, %{stopping?: true} = state) do
    {:noreply, %{state | lease_timer: nil}}
  end

  def handle_info(:renew_lease, state) do
    handle_lease_renewal(%{state | lease_timer: nil})
  end

  def handle_info({:EXIT, _from, reason}, state) when reason != :normal do
    handle_fatal_run_stop(state, reason)
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if state.inbox, do: Inbox.cancel(state.inbox)
    if state.lease_timer, do: Process.cancel_timer(state.lease_timer)
    stop_active_sender(state.active_block)

    if state.claim != nil and not state.keep_claim_on_exit? do
      release_clean_consumer(state)
    end

    :ok
  end

  # ---------------------------------------------------------------------------
  # Run establishment
  # ---------------------------------------------------------------------------

  defp establish_run(state) do
    request_start = now_ms()

    with {:ok, target} <- state.hooks.target_resolver.(state.member),
         {:ok, gate} <- state.hooks.recovery_gate_fn.(),
         {:ok, {origin, relay}} <- open_active_relay(state),
         {:ok, pipeline} <- state.hooks.pipeline_resolver.(relay.id, relay.media_ingest_id),
         {:ok, owner} <- state.hooks.ingest_owner_fn.(relay.id, state.actor),
         {:ok, claim} <-
           state.hooks.acquire_claim_fn.(
             owner,
             state.claim_token,
             relay.media_ingest_id,
             target.storage_id,
             state.lease_ms,
             actor: state.actor,
             timeout: @call_cap_ms
           ) do
      lease_deadline = claim_lease_deadline(request_start, claim)
      run_id = "#{owner.relay_session_id}:#{claim.recorder_epoch}"

      base_state = %{
        state
        | storage_id: target.storage_id,
          client_config: target.client_config,
          recovery_gate: gate,
          relay_session_id: relay.id,
          relay_origin: origin,
          media_ingest_id: relay.media_ingest_id,
          owner: owner,
          claim: claim,
          lease_deadline: lease_deadline,
          run_id: run_id,
          pipeline: pipeline,
          pipeline_monitor: Process.monitor(pipeline)
      }

      attach_run_inbox(base_state, lease_deadline)
    else
      {:error, reason} ->
        {:error, reason, state}
    end
  end

  defp attach_run_inbox(state, lease_deadline) do
    with {:ok, inbox} <-
           state.hooks.inbox_new_fn.(
             state.pipeline,
             state.relay_session_id,
             state.media_ingest_id,
             lease_deadline,
             state.inbox_opts
           ),
         :ok <- state.hooks.attach_pipeline_fn.(state.pipeline, inbox, @call_cap_ms) do
      ready =
        state
        |> Map.merge(%{inbox: inbox, phase: :idle})
        |> schedule_renewal()

      {:ok, ready}
    else
      {:error, reason} ->
        {:error, reason, state}
    end
  end

  defp open_active_relay(state) do
    case state.hooks.relay_open_fn.(state.policy.camera_source_id, state.policy.stream_profile_id, state.actor) do
      {:ok, {origin, %{status: :active, media_ingest_id: ingest_id} = relay}}
      when is_binary(ingest_id) and ingest_id != "" ->
        {:ok, {origin, relay}}

      {:ok, {origin, %{id: relay_id}}} ->
        deadline = now_ms() + @relay_open_timeout_ms
        await_active_relay(state, origin, relay_id, deadline)

      {:error, _} = error ->
        error
    end
  end

  defp await_active_relay(state, origin, relay_id, deadline) do
    case state.hooks.relay_get_fn.(relay_id, state.actor) do
      {:ok, %{status: :active, media_ingest_id: ingest_id} = relay}
      when is_binary(ingest_id) and ingest_id != "" ->
        {:ok, {origin, relay}}

      {:ok, %{status: status}} when status in [:requested, :opening] ->
        if now_ms() < deadline do
          Process.sleep(@relay_poll_interval_ms)
          await_active_relay(state, origin, relay_id, deadline)
        else
          {:error, :relay_open_timeout}
        end

      {:ok, %{status: status}} ->
        {:error, {:relay_session_terminal, status}}

      {:error, _} = error ->
        error
    end
  end

  # ---------------------------------------------------------------------------
  # Incoming media unit handling & keyframe-aligned handover (A.3.2, A.3.4)
  # ---------------------------------------------------------------------------

  defp handle_incoming_unit(state, unit) do
    case validate_unit(state, unit) do
      :ok ->
        state = update_unit_duration(state, unit)
        route_valid_unit(state, unit)

      {:sequence_skip, expected_seq} ->
        handle_sequence_skip(state, unit, expected_seq)

      {:discontinuity, detail_class} ->
        handle_timestamp_discontinuity(state, unit, detail_class)
    end
  end

  defp validate_unit(state, unit) do
    cond do
      unit.dts != unit.pts ->
        {:discontinuity, "reordered_dts"}

      state.last_admitted_pts != nil and unit.pts < state.last_admitted_pts ->
        {:discontinuity, "timestamp_discontinuity"}

      state.last_admitted_sequence != nil and unit.sequence != state.last_admitted_sequence + 1 ->
        {:sequence_skip, state.last_admitted_sequence + 1}

      true ->
        :ok
    end
  end

  defp update_unit_duration(%{last_admitted_pts: prev_pts} = state, unit)
       when is_integer(prev_pts) and unit.pts > prev_pts do
    delta = unit.pts - prev_pts
    %{state | last_unit_duration_ticks: delta}
  end

  defp update_unit_duration(state, _unit), do: state

  defp handle_sequence_skip(state, unit, _expected_seq) do
    state =
      state
      |> note_gap_start(:source_unavailable, "media_sequence_discontinuity", unit)
      |> record_last_admitted(unit)
      |> Map.put(:next_contiguous?, false)

    case state.phase do
      :streaming ->
        # Finish current block before the skip, then buffer the post-skip unit.
        state = finish_active_block_input(state)
        {:noreply, enqueue_handover_unit(state, unit)}

      _ ->
        route_valid_unit(state, unit)
    end
  end

  defp handle_timestamp_discontinuity(state, unit, detail_class) do
    state =
      state
      |> note_gap_start(:source_unavailable, detail_class, unit)
      |> record_last_admitted(unit)
      |> Map.merge(%{
        next_contiguous?: false,
        awaiting_keyframe?: true,
        anchor_pts: nil,
        anchor_utc_us: nil,
        anchor_id: nil
      })

    case state.phase do
      :streaming ->
        state = finish_active_block_input(state)
        {:noreply, enqueue_handover_unit(state, unit)}

      _ ->
        route_valid_unit(state, unit)
    end
  end

  defp route_valid_unit(%{phase: :idle} = state, unit) do
    state = record_last_admitted(state, unit)

    if state.awaiting_keyframe? and not keyframe_unit?(unit) do
      release_inbox_credit(state, byte_size(unit.payload))
      {:noreply, note_gap_start(state, :keyframe_wait, "awaiting_idr", unit)}
    else
      state = flush_pending_gap(state, unit)
      start_block_with_unit(%{state | awaiting_keyframe?: false}, unit)
    end
  end

  defp route_valid_unit(%{phase: :streaming} = state, unit) do
    state = record_last_admitted(state, unit)
    accept_unit_into_active_block(state, unit)
  end

  defp route_valid_unit(%{phase: :sealing} = state, unit) do
    state = record_last_admitted(state, unit)
    {:noreply, enqueue_handover_unit(state, unit)}
  end

  defp route_valid_unit(state, unit) do
    release_inbox_credit(state, byte_size(unit.payload))
    {:noreply, state}
  end

  defp record_last_admitted(state, unit) do
    %{
      state
      | last_admitted_sequence: unit.sequence,
        last_admitted_pts: unit.pts,
        last_admitted_at_us: unit.admitted_at_us
    }
  end

  defp accept_unit_into_active_block(%{active_block: block} = state, unit) do
    unit_bytes = byte_size(unit.payload)
    next_bytes = block.bytes_accepted + unit_bytes
    soft_reached? = soft_bound_reached?(block, state.bounds)

    cond do
      # Sequence discontinuity relative to the active block (e.g. after handover overflow):
      # close the current block and start the next block with this unit (or next IDR).
      block.last_sequence != nil and unit.sequence != block.last_sequence + 1 ->
        state = finish_active_block_input(%{state | next_contiguous?: false})
        {:noreply, enqueue_handover_unit(state, unit)}

      # Soft target reached and an IDR arrived -> clean keyframe-aligned cut!
      soft_reached? and keyframe_unit?(unit) ->
        state = finish_active_block_input(state)
        {:noreply, enqueue_handover_unit(state, unit)}

      # Hard byte ceiling would be exceeded by this unit -> cut before this unit.
      next_bytes > state.bounds.max_bytes ->
        handle_hard_byte_cut(state, unit)

      # Accept unit into the current block, then check hard frame/duration ceilings.
      true ->
        next_frames = block.frames_accepted + 1
        duration_ticks = unit.pts - block.first_pts
        max_duration_ticks = ms_to_ticks(state.bounds.max_duration_ms)
        hard_reached? = next_frames >= state.bounds.max_frames or duration_ticks >= max_duration_ticks

        next_block = %{
          block
          | queue: :queue.in(unit, block.queue),
            last_pts: unit.pts,
            last_sequence: unit.sequence,
            frames_accepted: next_frames,
            bytes_accepted: next_bytes
        }

        state = maybe_reply_puller(%{state | active_block: next_block})

        if hard_reached? do
          {:noreply, finish_active_block_input(%{state | awaiting_keyframe?: true})}
        else
          {:noreply, state}
        end
    end
  end

  defp handle_hard_byte_cut(state, unit) do
    state = finish_active_block_input(state)

    if keyframe_unit?(unit) do
      {:noreply, enqueue_handover_unit(state, unit)}
    else
      release_inbox_credit(state, byte_size(unit.payload))
      state = note_gap_start(state, :keyframe_wait, "hard_byte_bound_non_idr", unit)
      {:noreply, %{state | awaiting_keyframe?: true, next_contiguous?: false}}
    end
  end

  defp soft_bound_reached?(block, bounds) do
    duration_ticks = (block.last_pts || block.first_pts) - block.first_pts

    block.frames_accepted >= bounds.soft_frames or
      block.bytes_accepted >= bounds.soft_bytes or
      duration_ticks >= ms_to_ticks(bounds.soft_duration_ms)
  end

  defp enqueue_handover_unit(state, unit) do
    unit_bytes = byte_size(unit.payload)

    if state.handover_samples >= state.handover_max_samples or
         state.handover_bytes + unit_bytes > state.handover_max_bytes do
      # Bounded handover queue overflow: drop unit, release inbox credit, record exact gap.
      release_inbox_credit(state, unit_bytes)

      state
      |> note_gap_start(:handover_overflow, "handover_queue_full", unit)
      |> Map.put(:awaiting_keyframe?, state.handover_samples == 0)
    else
      %{
        state
        | handover_queue: :queue.in(unit, state.handover_queue),
          handover_samples: state.handover_samples + 1,
          handover_bytes: state.handover_bytes + unit_bytes
      }
    end
  end

  defp drain_handover_queue(%{stopping?: true} = state) do
    drain_and_release_handover(state)
    complete_graceful_stop(state)
  end

  defp drain_handover_queue(%{handover_samples: 0} = state), do: {:noreply, state}

  defp drain_handover_queue(state) do
    {{:value, unit}, rest} = :queue.out(state.handover_queue)

    state = %{
      state
      | handover_queue: rest,
        handover_samples: state.handover_samples - 1,
        handover_bytes: state.handover_bytes - byte_size(unit.payload)
    }

    drain_one_handover_unit(state, unit)
  end

  defp drain_one_handover_unit(%{phase: :idle, awaiting_keyframe?: true} = state, unit) do
    if keyframe_unit?(unit) do
      start_from_handover_unit(state, unit)
    else
      release_inbox_credit(state, byte_size(unit.payload))

      state
      |> note_gap_start(:keyframe_wait, "awaiting_idr", unit)
      |> drain_handover_queue()
    end
  end

  defp drain_one_handover_unit(%{phase: :idle} = state, unit), do: start_from_handover_unit(state, unit)

  defp drain_one_handover_unit(%{phase: :streaming} = state, unit) do
    case accept_unit_into_active_block(state, unit) do
      {:noreply, %{phase: :streaming} = next} -> drain_handover_queue(next)
      other -> other
    end
  end

  defp drain_one_handover_unit(state, unit) do
    restored = %{
      state
      | handover_queue: :queue.in_r(unit, state.handover_queue),
        handover_samples: state.handover_samples + 1,
        handover_bytes: state.handover_bytes + byte_size(unit.payload)
    }

    {:noreply, restored}
  end

  defp start_from_handover_unit(state, unit) do
    state = flush_pending_gap(state, unit)

    case start_block_with_unit(%{state | awaiting_keyframe?: false}, unit) do
      {:noreply, %{phase: :streaming} = next} -> drain_handover_queue(next)
      other -> other
    end
  end

  defp drain_and_release_handover(state) do
    case :queue.out(state.handover_queue) do
      {{:value, unit}, rest} ->
        release_inbox_credit(state, byte_size(unit.payload))
        drain_and_release_handover(%{state | handover_queue: rest})

      {:empty, _} ->
        :ok
    end
  end

  # ---------------------------------------------------------------------------
  # Block reservation & sender lifecycle
  # ---------------------------------------------------------------------------

  defp start_block_with_unit(state, unit) do
    unit_bytes = byte_size(unit.payload)

    if unit_bytes > state.bounds.max_bytes do
      release_inbox_credit(state, unit_bytes)
      state = record_immediate_gap(state, :run_stopped, "frame_exceeds_max_bytes")
      handle_fatal_run_stop(state, :frame_exceeds_max_bytes)
    else
      reserve_and_start_block(state, unit, unit_bytes)
    end
  end

  defp reserve_and_start_block(state, unit, unit_bytes) do
    retained_clock = %{
      "clock_epoch" => state.run_id,
      "timebase" => @timebase,
      "dts_source" => "pts_no_reordering",
      "utc_mapping" => "unknown"
    }

    case state.hooks.reserve_block_fn.(
           state.owner,
           state.claim,
           retained_clock,
           actor: state.actor,
           timeout: @call_cap_ms
         ) do
      {:ok, block_record} ->
        activate_reserved_block(state, block_record, unit, unit_bytes)

      {:error, :recording_stopped} ->
        release_inbox_credit(state, unit_bytes)
        complete_graceful_stop(%{state | stopping?: true, stop_reason: :recording_stopped})

      {:error, reason} ->
        release_inbox_credit(state, unit_bytes)
        state = record_immediate_gap(state, :run_stopped, sanitize_detail_class(reason, "reserve_block_failed"))
        handle_fatal_run_stop(state, reason)
    end
  end

  defp activate_reserved_block(state, block_record, unit, unit_bytes) do
    header = build_wire_header(state.storage_id, state.recovery_gate.generation, block_record)
    contiguous? = compute_contiguous?(state, unit)
    {sender_pid, sender_monitor, sender_ref} = spawn_sender(state, header)

    active_block = %{
      record: block_record,
      wire_header: header,
      sender_pid: sender_pid,
      sender_monitor: sender_monitor,
      sender_ref: sender_ref,
      queue: :queue.in(unit, :queue.new()),
      input_complete?: false,
      eof_replied?: false,
      abort_reason: nil,
      first_pts: unit.pts,
      first_sequence: unit.sequence,
      first_admitted_at_us: unit.admitted_at_us,
      last_pts: unit.pts,
      last_sequence: unit.sequence,
      frames_accepted: 1,
      bytes_accepted: unit_bytes,
      frames_sent: 0,
      bytes_sent: 0,
      contiguous_with_previous: contiguous?
    }

    next = %{state | phase: :streaming, active_block: active_block, next_contiguous?: true}

    if state.bounds.max_frames == 1 do
      {:noreply, finish_active_block_input(next)}
    else
      {:noreply, next}
    end
  end

  defp compute_contiguous?(state, unit) do
    state.prev_block_last_sequence != nil and
      state.next_contiguous? and
      unit.sequence == state.prev_block_last_sequence + 1
  end

  defp finish_active_block_input(%{active_block: nil} = state), do: %{state | phase: :idle}

  defp finish_active_block_input(%{active_block: block} = state) do
    next_block = %{block | input_complete?: true}
    maybe_reply_puller(%{state | phase: :sealing, active_block: next_block})
  end

  defp spawn_sender(state, header) do
    worker = self()
    sender_ref = make_ref()
    client_config = state.client_config
    timeout_ms = state.send_timeout_ms
    send_fn = state.hooks.send_recording_fn

    {sender_pid, sender_monitor} =
      spawn_monitor(fn ->
        stream = Stream.resource(fn -> worker end, &pull_from_worker/1, fn _ -> :ok end)
        result = send_fn.(client_config, header, stream, timeout_ms)
        send(worker, {sender_ref, result})
      end)

    {sender_pid, sender_monitor, sender_ref}
  end

  defp pull_from_worker(worker) do
    case GenServer.call(worker, :pull_unit, :infinity) do
      {:unit, unit} -> {[unit], worker}
      :eof -> {:halt, worker}
      {:abort, reason} -> throw({:nvr_producer_aborted, reason})
    end
  end

  defp maybe_reply_puller(%{waiting_puller: nil} = state), do: state

  defp maybe_reply_puller(%{waiting_puller: from, active_block: block} = state) do
    cond do
      block.abort_reason != nil ->
        GenServer.reply(from, {:abort, block.abort_reason})
        %{state | waiting_puller: nil}

      not :queue.is_empty(block.queue) ->
        {{:value, unit}, rest} = :queue.out(block.queue)
        release_inbox_credit(state, byte_size(unit.payload))
        GenServer.reply(from, {:unit, unit})

        next_block = %{
          block
          | queue: rest,
            frames_sent: block.frames_sent + 1,
            bytes_sent: block.bytes_sent + byte_size(unit.payload)
        }

        %{state | active_block: next_block, waiting_puller: nil}

      block.input_complete? ->
        GenServer.reply(from, :eof)
        %{state | active_block: %{block | eof_replied?: true}, waiting_puller: nil}

      true ->
        state
    end
  end

  # ---------------------------------------------------------------------------
  # Sender outcome & uncertain resolution (A.3.3, design A3 table)
  # ---------------------------------------------------------------------------

  defp handle_sender_result(%{active_block: block} = state, send_result) do
    if block.sender_monitor, do: Process.demonitor(block.sender_monitor, [:flush])
    drain_remaining_block_queue(state, block.queue)
    storage_id = state.storage_id
    block_key = block.record.block_key

    case send_result do
      {:ok, %{status: :sealed_local, storage_id: ^storage_id, block_ids: [^block_key]}} ->
        handle_verified_seal(state, block)

      {:error, {:ingest_refused, status}} when status in @definite_refusals ->
        handle_nvr_refusal(state, block, status, nil)

      {:error, {:ingest_refused, status, body}} when status in @definite_refusals ->
        handle_nvr_refusal(state, block, status, body)

      other_result ->
        handle_uncertain_outcome(state, block, other_result)
    end
  end

  defp handle_verified_seal(state, block) do
    {catalog_outcome, state} = catalog_sealed_block(state, block)

    state = %{
      state
      | active_block: nil,
        phase: :idle,
        waiting_puller: nil,
        blocks_sealed: state.blocks_sealed + 1,
        prev_block_last_sequence: block.last_sequence,
        prev_block_last_pts: block.last_pts,
        next_contiguous?: true
    }

    notify(state, {:block_sealed, %{block_key: block.record.block_key, catalog: catalog_outcome}})
    drain_handover_queue(state)
  end

  defp handle_nvr_refusal(state, block, status, body) do
    detail_class = refusal_detail_class(status, body)
    state = record_block_gap(state, block, :nvr_refused, detail_class)

    state = %{
      state
      | active_block: nil,
        phase: :idle,
        waiting_puller: nil,
        prev_block_last_sequence: nil,
        prev_block_last_pts: nil,
        next_contiguous?: false,
        awaiting_keyframe?: true
    }

    notify(state, {:nvr_refused, %{block_key: block.record.block_key, status: status, detail_class: detail_class}})

    if detail_class == "nvr_recovery_closed" do
      handle_fatal_run_stop(state, :nvr_recovery_closed)
    else
      drain_handover_queue(state)
    end
  end

  defp handle_uncertain_outcome(state, block, raw_result) do
    block_key = block.record.block_key

    case resolve_uncertain_via_lookup(state, block_key, state.lookup_max_attempts) do
      {:ok, :sealed} ->
        handle_verified_seal(state, block)

      {:ok, :absent} ->
        state = record_block_gap(state, block, :block_absent, "uncertain_resolved_absent")

        state = %{
          state
          | active_block: nil,
            phase: :idle,
            waiting_puller: nil,
            prev_block_last_sequence: nil,
            prev_block_last_pts: nil,
            next_contiguous?: false,
            awaiting_keyframe?: true
        }

        notify(state, {:uncertain_resolved, %{block_key: block_key, resolution: :absent}})
        drain_handover_queue(state)

      {:ok, unresolved_state} when unresolved_state in [:incomplete, :unresolved] ->
        state = record_block_gap(state, block, :run_stopped, "block_#{unresolved_state}")

        state = %{
          state
          | active_block: nil,
            phase: :stopped,
            waiting_puller: nil,
            keep_claim_on_exit?: false
        }

        notify(state, {:uncertain_resolved, %{block_key: block_key, resolution: unresolved_state}})
        notify(state, {:run_stopped, %{reason: {:unresolved_block, unresolved_state}, run_id: state.run_id}})
        {:stop, :normal, state}

      {:error, lookup_reason} ->
        Logger.warning(
          "ContinuousRecorder uncertain block #{block_key} lookup failed (#{inspect(lookup_reason, limit: 6)}, send=#{inspect(raw_result, limit: 6)})"
        )

        state = record_block_gap(state, block, :run_stopped, "nvr_unreachable")

        state = %{
          state
          | active_block: nil,
            phase: :stopped,
            waiting_puller: nil,
            keep_claim_on_exit?: true
        }

        notify(state, {:uncertain_resolved, %{block_key: block_key, resolution: :unreachable}})
        notify(state, {:run_stopped, %{reason: :nvr_unreachable, run_id: state.run_id}})
        {:stop, :normal, state}
    end
  end

  defp resolve_uncertain_via_lookup(state, block_key, attempts_left) when attempts_left > 0 do
    case state.hooks.lookup_blocks_fn.(state.client_config, [block_key], state.lookup_timeout_ms) do
      {:ok, %{storage_id: storage_id, blocks: [%{block_id: ^block_key, state: block_state} | _]}}
      when storage_id == state.storage_id and block_state in [:sealed, :absent, :incomplete, :unresolved] ->
        {:ok, block_state}

      {:ok, _unexpected} ->
        {:error, :invalid_lookup_response}

      {:error, reason} ->
        retry_or_fail_lookup(state, block_key, attempts_left - 1, reason)
    end
  end

  defp resolve_uncertain_via_lookup(_state, _block_key, _attempts_left), do: {:error, :nvr_unreachable}

  defp retry_or_fail_lookup(_state, _block_key, 0, reason), do: {:error, reason}

  defp retry_or_fail_lookup(state, block_key, attempts_left, _reason) do
    if state.lookup_retry_delay_ms > 0, do: Process.sleep(state.lookup_retry_delay_ms)
    resolve_uncertain_via_lookup(state, block_key, attempts_left)
  end

  # ---------------------------------------------------------------------------
  # Cataloging, drift check & re-anchoring (A.3.5, design T)
  # ---------------------------------------------------------------------------

  defp catalog_sealed_block(state, block) do
    {time_attrs, next_state} = compute_time_basis_and_anchor(state, block)

    catalog_attrs =
      Map.merge(time_attrs, %{
        policy_id: state.policy.id,
        policy_storage: state.policy.storage
      })

    outcome =
      with {:ok, _gate} <- state.hooks.recovery_gate_fn.(),
           {:ok, descriptor} <-
             state.hooks.block_descriptor_fn.(
               state.client_config,
               block.record.block_key,
               ServiceRadarNVRClient.descriptor_timeout_ms()
             ),
           {:ok, entry} <-
             state.hooks.freeze_and_catalog_fn.(
               state.owner,
               state.claim,
               block.record,
               descriptor,
               catalog_attrs,
               actor: state.actor,
               timeout: @call_cap_ms
             ) do
        _ = state.hooks.enqueue_archive_fn.(entry)
        {:registered, entry.id}
      else
        {:error, reason} ->
          Logger.warning(
            "ContinuousRecorder block #{block.record.block_key} catalog failed: #{inspect(reason, limit: 8)}"
          )

          {:unregistered, reason}
      end

    {outcome, next_state}
  end

  @doc false
  def compute_time_basis_and_anchor(%{anchor_pts: nil} = state, block) do
    anchor_id = "#{state.run_id}:#{block.record.block_sequence}"

    attrs = %{
      time_basis: :received,
      first_unit_pts: block.first_pts,
      first_unit_received_at: DateTime.from_unix!(block.first_admitted_at_us, :microsecond),
      timeline_start_us: block.first_admitted_at_us,
      run_id: state.run_id,
      anchor_id: anchor_id,
      reanchored: false,
      contiguous_with_previous: false
    }

    next_state = %{
      state
      | anchor_id: anchor_id,
        anchor_pts: block.first_pts,
        anchor_utc_us: block.first_admitted_at_us
    }

    {attrs, next_state}
  end

  def compute_time_basis_and_anchor(state, block) do
    pts_delta = block.first_pts - state.anchor_pts

    if pts_delta < 0 do
      reanchor_block(state, block, false)
    else
      estimated_utc_us = state.anchor_utc_us + ticks_to_us(pts_delta)
      drift_us = abs(block.first_admitted_at_us - estimated_utc_us)

      if drift_us > state.drift_threshold_us do
        reanchor_block(state, block, block.contiguous_with_previous)
      else
        attrs = %{
          time_basis: :received,
          first_unit_pts: block.first_pts,
          first_unit_received_at: DateTime.from_unix!(block.first_admitted_at_us, :microsecond),
          timeline_start_us: estimated_utc_us,
          run_id: state.run_id,
          anchor_id: state.anchor_id,
          reanchored: false,
          contiguous_with_previous: block.contiguous_with_previous
        }

        {attrs, state}
      end
    end
  end

  defp reanchor_block(state, block, contiguous?) do
    new_anchor_id = "#{state.run_id}:#{block.record.block_sequence}"

    attrs = %{
      time_basis: :received,
      first_unit_pts: block.first_pts,
      first_unit_received_at: DateTime.from_unix!(block.first_admitted_at_us, :microsecond),
      timeline_start_us: block.first_admitted_at_us,
      run_id: state.run_id,
      anchor_id: new_anchor_id,
      reanchored: true,
      contiguous_with_previous: contiguous?
    }

    next_state = %{
      state
      | anchor_id: new_anchor_id,
        anchor_pts: block.first_pts,
        anchor_utc_us: block.first_admitted_at_us
    }

    {attrs, next_state}
  end

  # ---------------------------------------------------------------------------
  # Gap accounting (A.3.2, design A4, A7)
  # ---------------------------------------------------------------------------

  defp note_gap_start(%{pending_gap: nil} = state, reason, detail_class, unit) do
    {start_pts, start_us} = gap_origin(state, unit)

    %{
      state
      | pending_gap: %{
          reason: reason,
          detail_class: detail_class,
          start_pts: start_pts,
          start_us: start_us,
          first_skipped_sequence: unit.sequence
        }
    }
  end

  defp note_gap_start(state, _reason, _detail_class, _unit), do: state

  defp gap_origin(state, unit) do
    {unit.pts, pts_to_anchored_us(state, unit.pts, unit.admitted_at_us)}
  end

  defp flush_pending_gap(%{pending_gap: nil} = state, _next_unit), do: state

  defp flush_pending_gap(%{pending_gap: %{first_skipped_sequence: skipped_seq}} = state, %{sequence: seq})
       when seq < skipped_seq, do: state

  defp flush_pending_gap(%{pending_gap: gap} = state, next_unit) do
    media_gap_ticks = max(0, next_unit.pts - gap.start_pts)
    media_gap_ns = ticks_to_ns(media_gap_ticks)
    start_us = gap.start_us

    end_us =
      if state.anchor_pts != nil and next_unit.pts >= gap.start_pts do
        max(start_us, start_us + div(media_gap_ns, 1_000))
      else
        max(start_us, next_unit.admitted_at_us)
      end

    state =
      persist_gap(state, %{
        start_us: start_us,
        end_us: end_us,
        media_gap_ns: media_gap_ns,
        reason: gap.reason,
        detail_class: gap.detail_class
      })

    %{state | pending_gap: nil}
  end

  defp record_block_gap(state, block, reason, detail_class) do
    start_us = pts_to_anchored_us(state, block.first_pts, block.first_admitted_at_us)
    media_gap_ticks = max(0, block.last_pts + state.last_unit_duration_ticks - block.first_pts)
    media_gap_ns = ticks_to_ns(media_gap_ticks)
    end_us = max(start_us, start_us + div(media_gap_ns, 1_000))

    persist_gap(state, %{
      start_us: start_us,
      end_us: end_us,
      media_gap_ns: media_gap_ns,
      reason: reason,
      detail_class: detail_class
    })
  end

  defp record_immediate_gap(state, reason, detail_class) do
    now_us = state.last_admitted_at_us || System.os_time(:microsecond)

    persist_gap(state, %{
      start_us: now_us,
      end_us: now_us,
      media_gap_ns: nil,
      reason: reason,
      detail_class: detail_class
    })
  end

  defp maybe_record_startup_gap(_state, reason) when reason in [:recording_disabled, :recording_stopped], do: :ok

  defp maybe_record_startup_gap(state, reason) do
    gap_reason = if reason == :nvr_recovery_closed, do: :nvr_refused, else: :source_unavailable
    _ = record_immediate_gap(state, gap_reason, sanitize_detail_class(reason, "startup_failed"))
    :ok
  end

  defp persist_gap(state, attrs) do
    full_attrs =
      Map.merge(
        %{
          camera_source_id: state.policy.camera_source_id,
          stream_profile_id: state.policy.stream_profile_id,
          policy_id: state.policy.id,
          storage_id: state.storage_id,
          run_id: state.run_id,
          clock_epoch: state.run_id,
          time_basis: :received,
          time_uncertainty_us: nil
        },
        attrs
      )

    case state.hooks.record_gap_fn.(full_attrs, actor: state.actor) do
      {:ok, _gap} ->
        notify(state, {:gap_recorded, full_attrs})
        %{state | gaps_recorded: state.gaps_recorded + 1}

      {:error, reason} ->
        Logger.warning("ContinuousRecorder gap insert failed: #{inspect(reason, limit: 8)}")
        state
    end
  end

  # ---------------------------------------------------------------------------
  # Lease renewal & shutdown
  # ---------------------------------------------------------------------------

  defp handle_lease_renewal(state) do
    request_start = now_ms()

    with {:ok, _gate} <- state.hooks.recovery_gate_fn.(),
         {:ok, claim} <-
           state.hooks.renew_claim_fn.(
             state.owner,
             state.claim,
             state.lease_ms,
             actor: state.actor,
             timeout: @call_cap_ms
           ),
         lease_deadline = claim_lease_deadline(request_start, claim),
         :ok <- renew_inbox(state.inbox, lease_deadline) do
      {:noreply, schedule_renewal(%{state | claim: claim, lease_deadline: lease_deadline})}
    else
      {:error, :recording_stopped} ->
        handle_graceful_stop(state, :recording_stopped)

      {:error, reason} ->
        state = record_immediate_gap(state, :run_stopped, sanitize_detail_class(reason, "lease_renewal_failed"))
        handle_fatal_run_stop(state, reason)
    end
  end

  defp handle_graceful_stop(%{stopping?: true} = state, _reason), do: {:noreply, state}

  defp handle_graceful_stop(state, reason) do
    state = %{state | stopping?: true, stop_reason: reason}

    case state.phase do
      :streaming ->
        {:noreply, finish_active_block_input(state)}

      :sealing ->
        {:noreply, state}

      _ ->
        complete_graceful_stop(state)
    end
  end

  defp complete_graceful_stop(state) do
    if state.inbox, do: Inbox.cancel(state.inbox)
    state = cancel_lease_timer(state)
    notify(state, {:run_stopped, %{reason: state.stop_reason || :stopped, run_id: state.run_id}})
    {:stop, :normal, %{state | phase: :stopped}}
  end

  defp handle_relay_ended(state, gap_reason, detail_class) do
    state = %{state | detached?: true, stopping?: true, stop_reason: gap_reason}

    case state.phase do
      :streaming ->
        state = record_immediate_gap(state, gap_reason, detail_class)
        {:noreply, finish_active_block_input(state)}

      :sealing ->
        state = record_immediate_gap(state, gap_reason, detail_class)
        {:noreply, state}

      _ ->
        state = record_immediate_gap(state, gap_reason, detail_class)
        complete_graceful_stop(state)
    end
  end

  defp handle_fatal_run_stop(state, reason) do
    if state.inbox, do: Inbox.cancel(state.inbox)
    state = cancel_lease_timer(state)
    stop_active_sender(state.active_block)
    drain_and_release_handover(state)
    notify(state, {:run_stopped, %{reason: reason, run_id: state.run_id}})
    {:stop, :normal, %{state | active_block: nil, phase: :stopped, stopping?: true, stop_reason: reason}}
  end

  defp stop_active_sender(%{sender_pid: pid}) when is_pid(pid) do
    if Process.alive?(pid), do: Process.exit(pid, :kill)
    :ok
  end

  defp stop_active_sender(_), do: :ok

  defp drain_remaining_block_queue(state, queue) do
    case :queue.out(queue) do
      {{:value, unit}, rest} ->
        release_inbox_credit(state, byte_size(unit.payload))
        drain_remaining_block_queue(state, rest)

      {:empty, _} ->
        :ok
    end
  end

  defp release_clean_consumer(state) do
    _ =
      state.hooks.release_claim_fn.(
        state.owner,
        state.claim,
        actor: state.actor,
        timeout: RecorderRenewal.cleanup_timeout_ms()
      )

    if state.relay_origin == :new and is_binary(state.relay_session_id) do
      _ = state.hooks.relay_close_fn.(state.relay_session_id, "continuous recorder stopped", state.actor)
    end

    :ok
  catch
    _kind, _reason -> :ok
  end

  # ---------------------------------------------------------------------------
  # Helpers & validation
  # ---------------------------------------------------------------------------

  defp annexb_contains_idr?(<<>>), do: false

  defp annexb_contains_idr?(<<0, 0, 0, 1, nal_header, rest::binary>>) do
    if (nal_header &&& 0x1F) == 5, do: true, else: annexb_contains_idr?(rest)
  end

  defp annexb_contains_idr?(<<0, 0, 1, nal_header, rest::binary>>) do
    if (nal_header &&& 0x1F) == 5, do: true, else: annexb_contains_idr?(rest)
  end

  defp annexb_contains_idr?(<<_byte, rest::binary>>), do: annexb_contains_idr?(rest)

  defp build_wire_header(storage_id, recovery_generation, block) do
    identity =
      block
      |> RecordingBlock.identity()
      |> Map.delete("clock")

    %{
      "version" => 1,
      "storage_id" => storage_id,
      "recovery_generation" => recovery_generation,
      "identity" => identity,
      "clock_epoch" => block.clock["clock_epoch"]
    }
  end

  defp refusal_detail_class(_status, %{"error" => raw}) when is_binary(raw), do: sanitize_detail_class(raw, "nvr_refused")

  defp refusal_detail_class(status, _body), do: "http_#{status}"

  defp sanitize_detail_class(value, fallback) when is_atom(value),
    do: value |> Atom.to_string() |> sanitize_detail_class(fallback)

  defp sanitize_detail_class(value, fallback) when is_binary(value) do
    sanitized =
      value
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9_:-]+/, "_")
      |> String.trim("_")
      |> String.slice(0, 64)

    if sanitized == "", do: fallback, else: sanitized
  end

  defp sanitize_detail_class(_value, fallback), do: fallback

  defp pts_to_anchored_us(%{anchor_pts: anchor_pts, anchor_utc_us: anchor_utc_us}, pts, _fallback_us)
       when is_integer(anchor_pts) and is_integer(anchor_utc_us) and pts >= anchor_pts do
    anchor_utc_us + ticks_to_us(pts - anchor_pts)
  end

  defp pts_to_anchored_us(_state, _pts, fallback_us) when is_integer(fallback_us), do: fallback_us
  defp pts_to_anchored_us(_state, _pts, _fallback_us), do: System.os_time(:microsecond)

  defp ms_to_ticks(ms), do: div(ms * @timebase, 1_000)
  defp ticks_to_us(ticks), do: div(ticks * 1_000_000, @timebase)
  defp ticks_to_ns(ticks), do: div(ticks * 1_000_000_000, @timebase)

  defp block_send_timeout_ms(bounds) do
    min(@block_send_timeout_ceiling_ms, bounds.max_duration_ms + @seal_headroom_ms)
  end

  defp validate_policy(
         %{camera_source_id: cam_id, stream_profile_id: prof_id, mode: :continuous, nvr_member: member} = policy
       )
       when is_binary(cam_id) and is_binary(prof_id) and is_binary(member) and member != "" do
    {:ok, policy}
  end

  defp validate_policy(_), do: {:error, :invalid_recording_policy}

  defp normalize_bounds(overrides) when is_map(overrides) do
    merged = Map.merge(@default_bounds, overrides)

    if valid_int?(merged.max_frames, 1, @max_frames_ceiling) and
         valid_int?(merged.soft_frames, 1, merged.max_frames) and
         valid_int?(merged.max_bytes, 1, @max_bytes_ceiling) and
         valid_int?(merged.soft_bytes, 1, merged.max_bytes) and
         valid_int?(merged.max_duration_ms, 100, @max_duration_ms_ceiling) and
         valid_int?(merged.soft_duration_ms, 100, merged.max_duration_ms) do
      {:ok, merged}
    else
      {:error, :invalid_capture_bounds}
    end
  end

  defp normalize_bounds(_), do: {:error, :invalid_capture_bounds}

  defp valid_int?(value, min_val, max_val), do: is_integer(value) and value >= min_val and value <= max_val

  defp release_inbox_credit(%{detached?: false, inbox: %Inbox{} = inbox}, bytes) do
    _ = Inbox.release(inbox, bytes)
    :ok
  end

  defp release_inbox_credit(_state, _bytes), do: :ok

  defp renew_inbox(nil, _deadline_ms), do: :ok
  defp renew_inbox(%Inbox{} = inbox, deadline_ms), do: Inbox.renew(inbox, deadline_ms)

  defp schedule_renewal(state) do
    state = cancel_lease_timer(state)

    delay =
      case state.inbox do
        %Inbox{} = inbox -> min(5_000, max(100, div(Inbox.remaining_ms(inbox), 2)))
        _ -> min(5_000, max(100, div(state.lease_ms, 3)))
      end

    %{state | lease_timer: Process.send_after(self(), :renew_lease, delay)}
  end

  defp cancel_lease_timer(%{lease_timer: nil} = state), do: state

  defp cancel_lease_timer(state) do
    Process.cancel_timer(state.lease_timer)
    %{state | lease_timer: nil}
  end

  defp claim_lease_deadline(request_start, %{lease_expires_at: expires_at, database_now: db_now}) do
    request_start + max(0, DateTime.diff(expires_at, db_now, :millisecond))
  end

  defp clear_puller(from, from), do: nil
  defp clear_puller(existing, _from), do: existing

  defp run_summary(state) do
    %{
      run_id: state.run_id,
      member: state.member,
      storage_id: state.storage_id,
      relay_session_id: state.relay_session_id,
      recorder_epoch: state.claim && state.claim.recorder_epoch
    }
  end

  defp notify(%{notify: pid}, event) when is_pid(pid), do: send(pid, {:continuous_recorder, self(), event})
  defp notify(_state, _event), do: :ok

  defp now_ms, do: System.monotonic_time(:millisecond)

  defp build_hooks(opts) do
    %{
      enabled_fn: Keyword.get(opts, :enabled_fn, &RecordingSupervisor.enabled?/0),
      target_resolver: Keyword.get(opts, :target_resolver, &NVRTargetConfig.resolve/1),
      recovery_gate_fn: Keyword.get(opts, :recovery_gate_fn, &default_recovery_gate/0),
      relay_open_fn: Keyword.get(opts, :relay_open_fn, &default_relay_open/3),
      relay_get_fn: Keyword.get(opts, :relay_get_fn, &default_relay_get/2),
      relay_close_fn: Keyword.get(opts, :relay_close_fn, &default_relay_close/3),
      pipeline_resolver: Keyword.get(opts, :pipeline_resolver, &PipelineManager.recording_pipeline/2),
      ingest_owner_fn: Keyword.get(opts, :ingest_owner_fn, &default_ingest_owner/2),
      acquire_claim_fn: Keyword.get(opts, :acquire_claim_fn, &RecorderOwnership.acquire/6),
      renew_claim_fn: Keyword.get(opts, :renew_claim_fn, &RecorderOwnership.renew/4),
      release_claim_fn: Keyword.get(opts, :release_claim_fn, &RecorderOwnership.release/3),
      reserve_block_fn: Keyword.get(opts, :reserve_block_fn, &RecorderOwnership.reserve_block/4),
      inbox_new_fn: Keyword.get(opts, :inbox_new_fn, &Inbox.new/5),
      attach_pipeline_fn: Keyword.get(opts, :attach_pipeline_fn, &default_attach_pipeline/3),
      send_recording_fn: Keyword.get(opts, :send_recording_fn, &ServiceRadarNVRClient.send_recording/4),
      lookup_blocks_fn: Keyword.get(opts, :lookup_blocks_fn, &ServiceRadarNVRClient.lookup_blocks/3),
      block_descriptor_fn: Keyword.get(opts, :block_descriptor_fn, &ServiceRadarNVRClient.block_descriptor/3),
      freeze_and_catalog_fn: Keyword.get(opts, :freeze_and_catalog_fn, &RecordingBlocks.freeze_and_catalog/6),
      enqueue_archive_fn: Keyword.get(opts, :enqueue_archive_fn, &ArchiveBlockJob.enqueue_for_entry/1),
      record_gap_fn: Keyword.get(opts, :record_gap_fn, &RecordingGap.record/2)
    }
  end

  defp default_recovery_gate do
    gate = Application.get_env(:serviceradar_core, :nvr_recovery_gate)

    case RecoveryGate.check(gate) do
      :ok -> {:ok, gate}
      {:error, _} = error -> error
    end
  end

  defp default_relay_open(source_id, profile_id, actor) do
    RelaySessionManager.request_open(source_id, profile_id, actor: actor, return_origin?: true)
  end

  defp default_relay_get(relay_id, actor) do
    RelaySession.get_by_id(relay_id, actor: actor)
  end

  defp default_relay_close(relay_id, reason, actor) do
    RelaySessionManager.request_close(relay_id, reason: reason, actor: actor)
  end

  defp default_ingest_owner(relay_id, actor) do
    IngestOwnership.for_relay(relay_id, actor: actor)
  end

  defp default_attach_pipeline(pipeline, inbox, timeout) do
    Membrane.Pipeline.call(pipeline, {:attach_recorder, inbox}, timeout)
  catch
    :exit, _reason -> {:error, :ingest_stopped}
  end
end
