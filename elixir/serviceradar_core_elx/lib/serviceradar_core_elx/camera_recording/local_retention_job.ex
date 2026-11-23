defmodule ServiceRadarCoreElx.CameraRecording.LocalRetentionJob do
  @moduledoc """
  Periodic Oban worker (`maintenance` queue, scheduled every 60 seconds) that
  enforces local NVR retention and capacity-driven ring eviction (`C.7`, design
  sections `C1`, `C2`, `C4`, `C6`, `C7`).

  The 60-second cron trigger fans out one unique per-member Oban job
  (`%{"member" => member}`) per configured NVR member so each member runs
  independently on its 60-second cadence with per-member uniqueness.

  For each NVR member pass:
  1. Verifies Core's recovery gate and the member's `GET /v1/status`
     (`storage_id` match, `recovery.state == :ready`, `inventory == :ready`).
  2. Resumes any catalog entries already in `local_state == :reclaiming` left by
     a prior worker crash before selecting new candidates.
  3. Skips loading `:present` catalog rows when neither space eviction nor age
     eviction can apply; otherwise loads oldest-first eligible rows with a
     bounded query limit and applies the `C1` eviction table over reconciled,
     non-quarantined entries (`local_state == :present`,
     `recording_block_id != nil`, `quarantine_reason == nil`):
     - Age eviction: kind (a) (`archive_state` in `[:verified, :deleted]`) older
       than `max_local_age` when `:limited`; kind (b) (`archive_state == :not_required`)
       older than `local_only_max_age` when `:limited`, regardless of full policy.
     - Space eviction (high water down to low water on effective byte budget or
       block cap): kind (a), and kind (b) only when `local_only_full_policy` is
       `:overwrite_oldest`, interleaved oldest-first (`timeline_start_us`,
       `sealed_at`/`inserted_at`, `block_key`).
     - Kind (c) (`:awaiting_binding`, `:pending`, `:failed_retryable`,
       `:failed_terminal`, `:deleting`, `:missing`) and row (q) (`:quarantined`)
       are never selected.
  4. Serializes each eviction with `RecordingHolds.begin_copy_deletion_intent/4`
     (PD5 hold check + `:reclaiming` transition + `:requested` disposition in one
     transaction), calls `ServiceRadarNVRClient.reclaim_block/3`, re-checks via
     `ServiceRadarNVRClient.lookup_blocks/2`, and transitions `local_state` to
     `:reclaimed` only after NVR confirms `:reclaimed` or `:absent`.
  5. Caps each pass at 500 blocks per member and leaves retryable failures in
     `:reclaiming` for the next 60-second pass.
  """

  # ServiceRadar runs OSS Oban (Oban.Engines.Basic), not Oban Pro.
  # credo:disable-for-next-line Jump.CredoChecks.UseObanProWorker
  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 3,
    unique: [
      period: 55,
      keys: [:member],
      states: [:available, :scheduled, :retryable]
    ]

  import Ash.Expr

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Camera.RecordingArchiveSettings
  alias ServiceRadar.Camera.RecordingCatalogEntry
  alias ServiceRadar.Camera.RecordingDisposition
  alias ServiceRadar.Camera.RecordingHolds
  alias ServiceRadarCoreElx.CameraRecording.NVRTargetConfig
  alias ServiceRadarRecordingControl.RecoveryGate

  require Ash.Query
  require Logger

  @system_actor SystemActor.system(:camera_nvr_local_retention)
  @actor_id "system:camera_nvr_local_retention"
  @max_blocks_per_pass 500
  @present_query_headroom_multiplier 2
  @lookup_batch_size 50
  @kind_a_states [:verified, :deleted]
  @default_high_water_percent 90
  @default_low_water_percent 80
  @telemetry_event [:serviceradar, :camera_recording, :local_retention, :pass]

  @type member_summary :: %{
          member: String.t(),
          storage_id: String.t(),
          status: :ok | :skipped,
          skipped_reason: atom() | nil,
          resumed: non_neg_integer(),
          reclaimed: non_neg_integer(),
          held_skipped: non_neg_integer(),
          deferred: non_neg_integer(),
          failed: non_neg_integer(),
          processed: non_neg_integer()
        }

  @doc "Maximum number of blocks processed per member per pass (`C.7`)."
  @spec max_blocks_per_pass() :: pos_integer()
  def max_blocks_per_pass, do: @max_blocks_per_pass

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"member" => member}}) when is_binary(member) do
    case run_member(member) do
      {:ok, _summary} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  def perform(%Oban.Job{}) do
    case enqueue_all() do
      {:ok, _jobs} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Enqueues one unique per-member retention job for every configured NVR member.

  Returns `{:ok, []}` cleanly when the NVR client is not configured on this
  deployment.
  """
  @spec enqueue_all(keyword()) :: {:ok, [Oban.Job.t()]} | {:error, term()}
  def enqueue_all(opts \\ []) when is_list(opts) do
    insert_fn = Keyword.get(opts, :insert_fn, &Oban.insert/1)

    case list_targets(opts) do
      {:ok, targets} ->
        enqueue_targets(targets, insert_fn)

      {:error, :nvr_client_not_configured} ->
        {:ok, []}

      {:error, _reason} = error ->
        error
    end
  end

  defp enqueue_targets(targets, insert_fn) do
    targets
    |> Enum.reduce_while({:ok, []}, fn %{member: member}, {:ok, acc} ->
      changeset = new(%{"member" => member})

      case insert_fn.(changeset) do
        {:ok, job} -> {:cont, {:ok, [job | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, jobs} -> {:ok, Enum.reverse(jobs)}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Runs one local retention pass for a single named NVR member.
  """
  @spec run_member(String.t(), keyword()) :: {:ok, member_summary()} | {:error, term()}
  def run_member(member, opts \\ []) when is_binary(member) and is_list(opts) do
    with {:ok, target} <- resolve_target(member, opts) do
      run_target(target, opts)
    end
  end

  @doc """
  Runs one local retention pass for an already-resolved NVR member target.

  Accepts injectable hooks in `opts` for deterministic unit testing:
  - `:recovery_gate_fn` (`(-> :ok | {:ok, generation} | {:error, atom()})`)
  - `:status_fn` (`(client_config -> {:ok, status} | {:error, term()})`)
  - `:settings_loader` (`(-> {:ok, settings} | {:error, term()})`)
  - `:reclaiming_loader` (`(storage_id -> {:ok, [entry]} | {:error, term()})`)
  - `:present_loader` (`(storage_id, query_opts -> {:ok, [entry]} | {:error, term()})`)
  - `:disposition_loader` (`(entry_id -> {:ok, disposition | nil} | {:error, term()})`)
  - `:begin_intent_fn` (`(entry_id, :local, attrs, opts -> {:ok, %{entry: entry, disposition: disp}} | {:error, term()})`)
  - `:record_step_fn` (`(disposition, step, extra_attrs, opts -> {:ok, disposition} | {:error, term()})`)
  - `:reclaim_fn` (`(client_config, block_id, request -> {:ok, receipt} | {:error, term()})`)
  - `:lookup_fn` (`(client_config, [block_id] -> {:ok, %{storage_id: uuid, blocks: [map()]}} | {:error, term()})`)
  - `:finalize_reclaimed_fn` (`(entry, now -> {:ok, entry} | {:error, term()})`)
  - `:now_fn` (`(-> DateTime.t())`)
  - `:max_blocks_per_pass` (positive integer, default `500`)
  """
  @spec run_target(NVRTargetConfig.resolved_target(), keyword()) :: {:ok, member_summary()}
  def run_target(%{member: member, storage_id: storage_id, client_config: client_config} = target, opts \\ [])
      when is_list(opts) do
    summary = empty_summary(member, storage_id)

    result =
      with {:ok, gate_generation} <- check_recovery_gate(opts),
           {:ok, status} <- fetch_ready_status(client_config, storage_id, gate_generation, opts),
           {:ok, settings} <- load_settings(opts) do
        execute_member_pass(target, status, settings, summary, opts)
      else
        {:skip, reason} ->
          %{summary | status: :skipped, skipped_reason: reason}
      end

    emit_pass_telemetry(result)
    {:ok, result}
  end

  defp execute_member_pass(target, status, settings, summary, opts) do
    limit = pass_limit(opts)
    now = now_fn(opts).()
    recovery_generation = status.recovery.generation
    capacity = status.capacity

    pass_ctx = %{
      target: target,
      recovery_generation: recovery_generation,
      now: now,
      settings: settings,
      settings_revision: settings_revision(settings),
      effective_settings: effective_settings_snapshot(settings, capacity),
      limit: limit,
      opts: opts
    }

    state = %{
      summary: summary,
      projected_used_bytes: capacity.used_bytes,
      projected_blocks: capacity.blocks
    }

    state = resume_reclaiming_entries(pass_ctx, state)

    if state.summary.processed >= limit do
      state.summary
    else
      evict_present_candidates(pass_ctx, capacity, state)
    end
  end

  defp resume_reclaiming_entries(pass_ctx, state) do
    case load_reclaiming_entries(pass_ctx.target.storage_id, pass_ctx.opts) do
      {:ok, []} ->
        state

      {:ok, entries} ->
        eligible =
          entries
          |> Enum.filter(&reclaim_resumable?/1)
          |> sort_oldest_first()
          |> Enum.take(remaining_budget(pass_ctx.limit, state.summary.processed))

        resume_batches(eligible, pass_ctx, state)

      {:error, reason} ->
        Logger.warning(
          "NVR local retention could not load reclaiming entries for #{pass_ctx.target.member}: #{inspect(reason, limit: 8)}"
        )

        %{state | summary: Map.update!(state.summary, :failed, &(&1 + 1))}
    end
  end

  defp resume_batches([], _pass_ctx, state), do: state

  defp resume_batches(entries, pass_ctx, state) do
    entries
    |> Enum.chunk_every(@lookup_batch_size)
    |> Enum.reduce_while(state, fn chunk, acc ->
      if acc.summary.processed >= pass_ctx.limit do
        {:halt, acc}
      else
        {:cont, resume_chunk(chunk, pass_ctx, acc)}
      end
    end)
  end

  defp resume_chunk(chunk, pass_ctx, state) do
    block_ids = Enum.map(chunk, & &1.block_key)

    case lookup_blocks(pass_ctx.target.client_config, block_ids, pass_ctx.target.storage_id, pass_ctx.opts) do
      {:ok, states_by_id} ->
        resume_entries(chunk, states_by_id, pass_ctx, state)

      {:error, _reason} ->
        %{state | summary: Map.update!(state.summary, :deferred, &(&1 + length(chunk)))}
    end
  end

  defp resume_entries(chunk, states_by_id, pass_ctx, state) do
    Enum.reduce_while(chunk, state, fn entry, acc ->
      if acc.summary.processed >= pass_ctx.limit do
        {:halt, acc}
      else
        block_state = Map.get(states_by_id, entry.block_key)
        {:cont, resume_single_entry(entry, block_state, pass_ctx, acc)}
      end
    end)
  end

  defp resume_single_entry(entry, %{state: state_atom}, pass_ctx, acc) when state_atom in [:reclaimed, :absent] do
    disposition = load_latest_local_disposition(entry.id, pass_ctx.opts)

    if disposition do
      _ = record_disposition_step(disposition, :verified_absent, %{}, pass_ctx.opts)
    end

    case finalize_reclaimed(entry, pass_ctx.now, pass_ctx.opts) do
      {:ok, _updated} ->
        update_summary(acc, %{resumed: 1, reclaimed: 1, processed: 1})

      {:error, _reason} ->
        update_summary(acc, %{deferred: 1, processed: 1})
    end
  end

  defp resume_single_entry(entry, %{state: :sealed} = lookup_entry, pass_ctx, acc) do
    disposition = load_latest_local_disposition(entry.id, pass_ctx.opts)
    operation_id = (disposition && disposition.operation_id) || Ecto.UUID.generate()
    freed_bytes = lookup_entry[:bytes] || entry.media_bytes || 0

    case reclaim_and_verify(entry, operation_id, disposition, pass_ctx) do
      :reclaimed ->
        acc
        |> deduct_projected_usage(freed_bytes)
        |> update_summary(%{resumed: 1, reclaimed: 1, processed: 1})

      :deferred_reclaimed ->
        acc
        |> deduct_projected_usage(freed_bytes)
        |> update_summary(%{deferred: 1, processed: 1})

      :deferred ->
        update_summary(acc, %{deferred: 1, processed: 1})
    end
  end

  defp resume_single_entry(_entry, _other_state, _pass_ctx, acc) do
    update_summary(acc, %{deferred: 1, processed: 1})
  end

  defp evict_present_candidates(pass_ctx, capacity, state) do
    query_spec = build_present_query_spec(capacity, pass_ctx, state)

    if present_query_needed?(query_spec) do
      load_and_evict_present_candidates(query_spec, pass_ctx, state)
    else
      state.summary
    end
  end

  defp load_and_evict_present_candidates(query_spec, pass_ctx, state) do
    case load_present_entries(pass_ctx.target.storage_id, query_spec, pass_ctx.opts) do
      {:ok, entries} ->
        candidates =
          entries
          |> Enum.filter(&present_eviction_eligible?/1)
          |> sort_oldest_first()

        state =
          if age_eviction_enabled?(query_spec) do
            run_age_eviction(candidates, pass_ctx, state)
          else
            state
          end

        state =
          if query_spec.space_needed? do
            run_space_eviction(candidates, query_spec, pass_ctx, state)
          else
            state
          end

        state.summary

      {:error, reason} ->
        Logger.warning(
          "NVR local retention could not load catalog entries for #{pass_ctx.target.member}: #{inspect(reason, limit: 8)}"
        )

        Map.update!(state.summary, :failed, &(&1 + 1))
    end
  end

  defp build_present_query_spec(capacity, pass_ctx, state) do
    thresholds = compute_watermarks(capacity, pass_ctx.settings)
    evict_for_bytes? = thresholds.effective_budget_bytes > 0 and capacity.used_bytes >= thresholds.high_water_bytes
    evict_for_blocks? = capacity.max_blocks > 0 and capacity.blocks >= thresholds.high_water_blocks

    space_needed? =
      (evict_for_bytes? or evict_for_blocks?) and
        not space_target_met?(state, thresholds, evict_for_bytes?, evict_for_blocks?)

    %{
      thresholds: thresholds,
      space_triggers: {evict_for_bytes?, evict_for_blocks?},
      space_needed?: space_needed?,
      full_policy: RecordingArchiveSettings.effective_local_only_full_policy(pass_ctx.settings),
      kind_a_age_cutoff:
        age_cutoff(pass_ctx.settings.max_local_age_mode, pass_ctx.settings.max_local_age_seconds, pass_ctx.now),
      kind_b_age_cutoff:
        age_cutoff(
          pass_ctx.settings.local_only_max_age_mode,
          pass_ctx.settings.local_only_max_age_seconds,
          pass_ctx.now
        ),
      limit: remaining_budget(pass_ctx.limit, state.summary.processed) * @present_query_headroom_multiplier
    }
  end

  defp present_query_needed?(query_spec) do
    query_spec.space_needed? or age_eviction_enabled?(query_spec)
  end

  defp age_eviction_enabled?(query_spec) do
    not is_nil(query_spec.kind_a_age_cutoff) or not is_nil(query_spec.kind_b_age_cutoff)
  end

  defp run_age_eviction(candidates, pass_ctx, state) do
    aged = select_aged_candidates(candidates, pass_ctx)
    final_state = evict_aged_candidates(aged, pass_ctx, state)
    Map.put(final_state, :aged_evicted_ids, MapSet.new(aged, fn {entry, _} -> entry.id end))
  end

  defp select_aged_candidates(candidates, pass_ctx) do
    Enum.flat_map(candidates, fn entry ->
      case age_eviction_reason(entry, pass_ctx.settings, pass_ctx.now) do
        nil -> []
        reason -> [{entry, reason}]
      end
    end)
  end

  defp evict_aged_candidates(aged, pass_ctx, state) do
    Enum.reduce_while(aged, state, fn {entry, reason}, acc ->
      if acc.summary.processed >= pass_ctx.limit do
        {:halt, acc}
      else
        {next_acc, _outcome} = evict_candidate(entry, reason, pass_ctx, acc)
        {:cont, next_acc}
      end
    end)
  end

  defp run_space_eviction(candidates, query_spec, pass_ctx, state) do
    space_candidates = select_space_candidates(candidates, pass_ctx.settings, state)
    evict_space_candidates(space_candidates, query_spec.thresholds, query_spec.space_triggers, pass_ctx, state)
  end

  defp select_space_candidates(candidates, settings, state) do
    full_policy = RecordingArchiveSettings.effective_local_only_full_policy(settings)
    already_tried = Map.get(state, :aged_evicted_ids, MapSet.new())

    candidates
    |> Enum.reject(&MapSet.member?(already_tried, &1.id))
    |> Enum.flat_map(&space_candidate_pair(&1, full_policy))
  end

  defp space_candidate_pair(entry, full_policy) do
    case space_eviction_reason(entry, full_policy) do
      nil -> []
      reason -> [{entry, reason}]
    end
  end

  defp evict_space_candidates(space_candidates, thresholds, {evict_for_bytes?, evict_for_blocks?}, pass_ctx, state) do
    Enum.reduce_while(space_candidates, state, fn {entry, reason}, acc ->
      cond do
        acc.summary.processed >= pass_ctx.limit ->
          {:halt, acc}

        space_target_met?(acc, thresholds, evict_for_bytes?, evict_for_blocks?) ->
          {:halt, acc}

        true ->
          {next_acc, _outcome} = evict_candidate(entry, reason, pass_ctx, acc)
          {:cont, next_acc}
      end
    end)
  end

  defp space_target_met?(state, thresholds, evict_for_bytes?, evict_for_blocks?) do
    bytes_met? = not evict_for_bytes? or state.projected_used_bytes <= thresholds.low_water_bytes
    blocks_met? = not evict_for_blocks? or state.projected_blocks <= thresholds.low_water_blocks
    bytes_met? and blocks_met?
  end

  defp evict_candidate(entry, reason, pass_ctx, state) do
    intent_attrs = %{
      reason: reason,
      settings_revision: pass_ctx.settings_revision,
      effective_settings: pass_ctx.effective_settings,
      actor_id: @actor_id
    }

    entry.id
    |> begin_deletion_intent(intent_attrs, pass_ctx.now, pass_ctx.opts)
    |> handle_intent_result(entry, pass_ctx, state)
  end

  defp handle_intent_result({:ok, %{entry: reclaiming_entry, disposition: disposition}}, _entry, pass_ctx, state) do
    case reclaim_and_verify(reclaiming_entry, disposition.operation_id, disposition, pass_ctx) do
      :reclaimed ->
        next_state =
          state
          |> deduct_projected_usage(reclaiming_entry.media_bytes || 0)
          |> update_summary(%{reclaimed: 1, processed: 1})

        {next_state, :reclaimed}

      :deferred_reclaimed ->
        next_state =
          state
          |> deduct_projected_usage(reclaiming_entry.media_bytes || 0)
          |> update_summary(%{deferred: 1, processed: 1})

        {next_state, :deferred}

      :deferred ->
        {update_summary(state, %{deferred: 1, processed: 1}), :deferred}
    end
  end

  defp handle_intent_result({:error, {:blocked_by_hold, _detail}}, _entry, _pass_ctx, state) do
    {update_summary(state, %{held_skipped: 1}), :held}
  end

  defp handle_intent_result({:error, reason}, _entry, _pass_ctx, state)
       when reason in [:quarantined_entry_pinned, :catalog_entry_not_found] do
    {state, :skipped}
  end

  defp handle_intent_result({:error, {tag, _}}, _entry, _pass_ctx, state)
       when tag in [:local_copy_not_deletable, :pinned_by_archive_state] do
    {state, :skipped}
  end

  defp handle_intent_result({:error, other_reason}, entry, pass_ctx, state) do
    Logger.warning(
      "NVR local retention intent failed for #{entry.block_key} on #{pass_ctx.target.member}: #{inspect(other_reason, limit: 8)}"
    )

    {update_summary(state, %{failed: 1}), :failed}
  end

  defp reclaim_and_verify(entry, operation_id, disposition, pass_ctx) do
    request = %{
      "version" => 1,
      "storage_id" => pass_ctx.target.storage_id,
      "recovery_generation" => pass_ctx.recovery_generation,
      "operation_id" => operation_id,
      "expected_descriptor_sha256" => entry.descriptor_sha256
    }

    case call_reclaim_block(pass_ctx.target.client_config, entry.block_key, request, pass_ctx.opts) do
      {:ok, _receipt} ->
        finalize_accepted_reclaim(entry, disposition, pass_ctx)

      {:error, :outcome_unknown} ->
        verify_or_fail_reclaim(entry, disposition, "outcome_unknown", pass_ctx)

      {:error, {:reclaim_status, 404, body}} ->
        verify_or_fail_reclaim(entry, disposition, reclaim_error_class({:reclaim_status, 404, body}), pass_ctx)

      {:error, reason} ->
        error_class = reclaim_error_class(reason)

        if disposition do
          _ = record_disposition_step(disposition, :failed, %{error_class: error_class}, pass_ctx.opts)
        end

        :deferred
    end
  end

  defp finalize_accepted_reclaim(entry, disposition, pass_ctx) do
    if disposition do
      _ = record_disposition_step(disposition, :executed, %{}, pass_ctx.opts)
    end

    case verify_and_finalize_reclaimed(entry, disposition, pass_ctx) do
      :reclaimed -> :reclaimed
      _deferred -> :deferred_reclaimed
    end
  end

  defp verify_or_fail_reclaim(entry, disposition, error_class, pass_ctx) do
    case verify_and_finalize_reclaimed(entry, disposition, pass_ctx) do
      :reclaimed ->
        :reclaimed

      :deferred_reclaimed ->
        :deferred_reclaimed

      :deferred ->
        if disposition do
          _ = record_disposition_step(disposition, :failed, %{error_class: error_class}, pass_ctx.opts)
        end

        :deferred
    end
  end

  defp verify_and_finalize_reclaimed(entry, disposition, pass_ctx) do
    case lookup_blocks(pass_ctx.target.client_config, [entry.block_key], pass_ctx.target.storage_id, pass_ctx.opts) do
      {:ok, states_by_id} ->
        confirm_lookup_and_finalize(Map.get(states_by_id, entry.block_key), entry, disposition, pass_ctx)

      {:error, _reason} ->
        :deferred
    end
  end

  defp confirm_lookup_and_finalize(%{state: state_atom}, entry, disposition, pass_ctx)
       when state_atom in [:reclaimed, :absent] do
    if disposition do
      _ = record_disposition_step(disposition, :verified_absent, %{}, pass_ctx.opts)
    end

    case finalize_reclaimed(entry, pass_ctx.now, pass_ctx.opts) do
      {:ok, _updated} -> :reclaimed
      {:error, _reason} -> :deferred_reclaimed
    end
  end

  defp confirm_lookup_and_finalize(_other, _entry, _disposition, _pass_ctx), do: :deferred

  defp age_eviction_reason(%{archive_state: state} = entry, settings, now) when state in @kind_a_states do
    if limited_age_expired?(entry, settings.max_local_age_mode, settings.max_local_age_seconds, now) do
      :max_local_age
    end
  end

  defp age_eviction_reason(%{archive_state: :not_required} = entry, settings, now) do
    if limited_age_expired?(entry, settings.local_only_max_age_mode, settings.local_only_max_age_seconds, now) do
      :local_only_max_age
    end
  end

  defp age_eviction_reason(_entry, _settings, _now), do: nil

  defp limited_age_expired?(entry, mode, seconds, now) do
    case age_cutoff(mode, seconds, now) do
      %DateTime{} = cutoff -> entry_older_than_cutoff?(entry, cutoff)
      nil -> false
    end
  end

  defp age_cutoff(:limited, seconds, now) when is_integer(seconds) do
    DateTime.shift(now, second: -seconds)
  end

  defp age_cutoff(_mode, _seconds, _now), do: nil

  defp space_eviction_reason(%{archive_state: state}, _full_policy) when state in @kind_a_states, do: :budget

  defp space_eviction_reason(%{archive_state: :not_required}, :overwrite_oldest), do: :local_only_overwrite

  defp space_eviction_reason(_entry, _full_policy), do: nil

  defp entry_older_than_cutoff?(entry, cutoff) do
    cond do
      match?(%DateTime{}, Map.get(entry, :sealed_at)) ->
        DateTime.compare(entry.sealed_at, cutoff) in [:lt, :eq]

      is_integer(Map.get(entry, :timeline_end_us)) ->
        entry.timeline_end_us <= DateTime.to_unix(cutoff, :microsecond)

      is_integer(Map.get(entry, :timeline_start_us)) ->
        entry.timeline_start_us <= DateTime.to_unix(cutoff, :microsecond)

      true ->
        false
    end
  end

  defp compute_watermarks(capacity, settings) do
    high_pct = settings.local_high_water_percent || @default_high_water_percent
    low_pct = settings.local_low_water_percent || @default_low_water_percent

    effective_budget_bytes =
      case {Map.get(capacity, :available_bytes), Map.get(capacity, :reserve_bytes)} do
        {avail, reserve} when is_integer(avail) and is_integer(reserve) ->
          min(capacity.max_spool_bytes, max(capacity.used_bytes + avail - reserve, 0))

        _ ->
          capacity.max_spool_bytes
      end

    %{
      effective_budget_bytes: effective_budget_bytes,
      high_water_bytes: div(effective_budget_bytes * high_pct, 100),
      low_water_bytes: div(effective_budget_bytes * low_pct, 100),
      high_water_blocks: div(capacity.max_blocks * high_pct, 100),
      low_water_blocks: div(capacity.max_blocks * low_pct, 100)
    }
  end

  defp reclaim_resumable?(entry) do
    entry.local_state == :reclaiming and
      is_binary(Map.get(entry, :recording_block_id)) and
      is_nil(Map.get(entry, :quarantine_reason)) and
      is_binary(Map.get(entry, :descriptor_sha256))
  end

  defp present_eviction_eligible?(entry) do
    entry.local_state == :present and
      is_binary(Map.get(entry, :recording_block_id)) and
      is_nil(Map.get(entry, :quarantine_reason)) and
      is_binary(Map.get(entry, :descriptor_sha256)) and
      entry.archive_state in [:verified, :deleted, :not_required]
  end

  defp sort_oldest_first(entries) do
    Enum.sort_by(entries, fn entry ->
      {
        Map.get(entry, :timeline_start_us) || 0,
        datetime_sort_key(Map.get(entry, :sealed_at) || Map.get(entry, :inserted_at)),
        Map.get(entry, :block_key) || ""
      }
    end)
  end

  defp datetime_sort_key(%DateTime{} = dt), do: DateTime.to_unix(dt, :microsecond)
  defp datetime_sort_key(_), do: 0

  defp check_recovery_gate(opts) do
    gate_fn = Keyword.get(opts, :recovery_gate_fn, &default_recovery_gate_check/0)

    case gate_fn.() do
      :ok -> {:ok, nil}
      {:ok, generation} -> {:ok, generation}
      {:error, reason} -> {:skip, reason}
    end
  end

  defp default_recovery_gate_check do
    gate = Application.get_env(:serviceradar_core, :nvr_recovery_gate)

    case RecoveryGate.check(gate) do
      :ok -> {:ok, gate.generation}
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch_ready_status(client_config, expected_storage_id, gate_generation, opts) do
    status_fn = Keyword.get(opts, :status_fn, &ServiceRadarNVRClient.status/1)

    case status_fn.(client_config) do
      {:ok, status} ->
        validate_member_status(status, expected_storage_id, gate_generation)

      {:error, _reason} ->
        {:skip, :status_unavailable}
    end
  end

  defp validate_member_status(status, expected_storage_id, gate_generation) do
    cond do
      status.storage_id != expected_storage_id ->
        Logger.warning(
          "NVR local retention skipping member: status storage_id #{inspect(status.storage_id)} did not match configured #{expected_storage_id}"
        )

        {:skip, :storage_id_mismatch}

      status.recovery.state != :ready or not is_binary(status.recovery.generation) ->
        {:skip, :member_recovery_closed}

      is_binary(gate_generation) and status.recovery.generation != gate_generation ->
        {:skip, :recovery_generation_mismatch}

      status.inventory != :ready or not is_map(status.capacity) ->
        {:skip, :inventory_not_ready}

      true ->
        {:ok, status}
    end
  end

  defp load_settings(opts) do
    loader =
      Keyword.get(opts, :settings_loader, fn ->
        RecordingArchiveSettings.get_settings(actor: @system_actor)
      end)

    case loader.() do
      {:ok, settings} when is_map(settings) -> {:ok, settings}
      {:error, _reason} -> {:skip, :settings_unavailable}
    end
  end

  defp load_reclaiming_entries(storage_id, opts) do
    loader = Keyword.get(opts, :reclaiming_loader, &default_reclaiming_loader/1)
    loader.(storage_id)
  end

  defp default_reclaiming_loader(storage_id) do
    RecordingCatalogEntry
    |> Ash.Query.for_read(:read, %{}, actor: @system_actor)
    |> Ash.Query.filter(
      storage_id == ^storage_id and
        local_state == :reclaiming and
        not is_nil(recording_block_id) and
        is_nil(quarantine_reason)
    )
    |> Ash.Query.sort(timeline_start_us: :asc, sealed_at: :asc, block_key: :asc)
    |> Ash.Query.limit(@max_blocks_per_pass)
    |> Ash.read(actor: @system_actor)
  end

  defp load_present_entries(storage_id, query_spec, opts) do
    loader = Keyword.get(opts, :present_loader, &default_present_loader/2)
    loader.(storage_id, query_spec)
  end

  defp default_present_loader(storage_id, query_spec) do
    storage_id
    |> present_entries_query(query_spec)
    |> Ash.read(actor: @system_actor)
  end

  @doc false
  @spec present_entries_query(String.t(), map()) :: Ash.Query.t()
  def present_entries_query(storage_id, query_spec) when is_binary(storage_id) and is_map(query_spec) do
    RecordingCatalogEntry
    |> Ash.Query.for_read(:read, %{}, actor: @system_actor)
    |> Ash.Query.filter(
      storage_id == ^storage_id and
        local_state == :present and
        not is_nil(recording_block_id) and
        is_nil(quarantine_reason)
    )
    |> apply_present_eligibility_filter(query_spec)
    |> Ash.Query.sort(timeline_start_us: :asc, sealed_at: :asc, block_key: :asc)
    |> Ash.Query.limit(query_spec.limit)
  end

  defp apply_present_eligibility_filter(query, %{space_needed?: true, full_policy: :overwrite_oldest}) do
    Ash.Query.filter(query, archive_state in [:verified, :deleted, :not_required])
  end

  defp apply_present_eligibility_filter(query, %{space_needed?: true, kind_b_age_cutoff: %DateTime{} = kind_b_cutoff}) do
    Ash.Query.filter(
      query,
      archive_state in [:verified, :deleted] or
        (archive_state == :not_required and sealed_at <= ^kind_b_cutoff)
    )
  end

  defp apply_present_eligibility_filter(query, %{space_needed?: true}) do
    Ash.Query.filter(query, archive_state in [:verified, :deleted])
  end

  defp apply_present_eligibility_filter(query, %{
         space_needed?: false,
         kind_a_age_cutoff: %DateTime{} = kind_a_cutoff,
         kind_b_age_cutoff: %DateTime{} = kind_b_cutoff
       }) do
    Ash.Query.filter(
      query,
      (archive_state in [:verified, :deleted] and sealed_at <= ^kind_a_cutoff) or
        (archive_state == :not_required and sealed_at <= ^kind_b_cutoff)
    )
  end

  defp apply_present_eligibility_filter(query, %{space_needed?: false, kind_a_age_cutoff: %DateTime{} = kind_a_cutoff}) do
    Ash.Query.filter(query, archive_state in [:verified, :deleted] and sealed_at <= ^kind_a_cutoff)
  end

  defp apply_present_eligibility_filter(query, %{space_needed?: false, kind_b_age_cutoff: %DateTime{} = kind_b_cutoff}) do
    Ash.Query.filter(query, archive_state == :not_required and sealed_at <= ^kind_b_cutoff)
  end

  defp load_latest_local_disposition(entry_id, opts) do
    loader = Keyword.get(opts, :disposition_loader, &default_disposition_loader/1)

    case loader.(entry_id) do
      {:ok, disposition} -> disposition
      _ -> nil
    end
  end

  defp default_disposition_loader(entry_id) do
    RecordingDisposition
    |> Ash.Query.for_read(:for_catalog_entry, %{catalog_entry_id: entry_id}, actor: @system_actor)
    |> Ash.Query.filter(copy == :local)
    |> Ash.read(actor: @system_actor)
    |> case do
      {:ok, rows} -> {:ok, List.last(rows)}
      {:error, _} = error -> error
    end
  end

  defp begin_deletion_intent(entry_id, attrs, now, opts) do
    intent_fn = Keyword.get(opts, :begin_intent_fn, &RecordingHolds.begin_copy_deletion_intent/4)
    intent_fn.(entry_id, :local, attrs, actor: @system_actor, now: now)
  end

  defp record_disposition_step(disposition, step, extra_attrs, opts) do
    step_fn = Keyword.get(opts, :record_step_fn, &RecordingHolds.record_disposition_step/4)
    step_fn.(disposition, step, extra_attrs, actor: @system_actor)
  end

  defp call_reclaim_block(client_config, block_id, request, opts) do
    reclaim_fn = Keyword.get(opts, :reclaim_fn, &ServiceRadarNVRClient.reclaim_block/3)
    reclaim_fn.(client_config, block_id, request)
  end

  defp lookup_blocks(client_config, block_ids, expected_storage_id, opts) do
    lookup_fn = Keyword.get(opts, :lookup_fn, &ServiceRadarNVRClient.lookup_blocks/2)

    case lookup_fn.(client_config, block_ids) do
      {:ok, %{storage_id: ^expected_storage_id, blocks: blocks}} when is_list(blocks) ->
        {:ok, Map.new(blocks, &{&1.block_id, &1})}

      {:ok, _mismatched} ->
        {:error, :storage_id_mismatch}

      {:error, _reason} = error ->
        error
    end
  end

  defp finalize_reclaimed(entry, now, opts) do
    finalize_fn = Keyword.get(opts, :finalize_reclaimed_fn, &default_finalize_reclaimed/2)
    finalize_fn.(entry, now)
  end

  defp default_finalize_reclaimed(entry, now) do
    entry
    |> Ash.Changeset.for_update(:transition_local_state, %{
      local_state: :reclaimed,
      local_state_at: now
    })
    |> Ash.Changeset.filter(expr(local_state == :reclaiming))
    |> Ash.update(actor: @system_actor)
  end

  defp list_targets(opts) do
    case Keyword.fetch(opts, :targets) do
      {:ok, targets} when is_list(targets) -> {:ok, targets}
      :error -> NVRTargetConfig.list_all(Keyword.get(opts, :target_opts, []))
    end
  end

  defp resolve_target(member, opts) do
    NVRTargetConfig.resolve(member, Keyword.get(opts, :target_opts, []))
  end

  defp settings_revision(settings) do
    case Map.get(settings, :updated_at) do
      %DateTime{} = dt -> DateTime.to_iso8601(dt)
      _ -> "default"
    end
  end

  defp effective_settings_snapshot(settings, capacity) do
    %{
      "local_high_water_percent" => settings.local_high_water_percent || @default_high_water_percent,
      "local_low_water_percent" => settings.local_low_water_percent || @default_low_water_percent,
      "max_local_age_mode" => to_string(settings.max_local_age_mode || :limited),
      "max_local_age_seconds" => settings.max_local_age_seconds,
      "local_only_full_policy" => to_string(RecordingArchiveSettings.effective_local_only_full_policy(settings)),
      "local_only_max_age_mode" => to_string(settings.local_only_max_age_mode || :unlimited),
      "local_only_max_age_seconds" => settings.local_only_max_age_seconds,
      "max_spool_bytes" => capacity.max_spool_bytes,
      "max_blocks" => capacity.max_blocks
    }
  end

  defp reclaim_error_class({:reclaim_status, status, %{"error" => raw}}) when is_binary(raw) do
    sanitize_error_class(raw, "reclaim_http_#{status}")
  end

  defp reclaim_error_class({:reclaim_status, status, _body}) when is_integer(status) do
    "reclaim_http_#{status}"
  end

  defp reclaim_error_class(reason) when is_atom(reason) do
    sanitize_error_class(Atom.to_string(reason), "reclaim_failed")
  end

  defp reclaim_error_class(_other), do: "reclaim_failed"

  defp sanitize_error_class(raw, fallback) when is_binary(raw) do
    cleaned =
      raw
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9_.:-]+/, "_")
      |> String.trim("_")
      |> String.slice(0, 64)

    if cleaned == "", do: fallback, else: cleaned
  end

  defp deduct_projected_usage(state, freed_bytes) do
    %{
      state
      | projected_used_bytes: max(state.projected_used_bytes - max(freed_bytes, 0), 0),
        projected_blocks: max(state.projected_blocks - 1, 0)
    }
  end

  defp update_summary(state, increments) do
    updated =
      Enum.reduce(increments, state.summary, fn {key, delta}, acc ->
        Map.update!(acc, key, &(&1 + delta))
      end)

    %{state | summary: updated}
  end

  defp remaining_budget(limit, processed), do: max(limit - processed, 0)

  defp pass_limit(opts) do
    case Keyword.get(opts, :max_blocks_per_pass, @max_blocks_per_pass) do
      n when is_integer(n) and n > 0 -> min(n, @max_blocks_per_pass)
      _ -> @max_blocks_per_pass
    end
  end

  defp now_fn(opts), do: Keyword.get(opts, :now_fn, &DateTime.utc_now/0)

  defp empty_summary(member, storage_id) do
    %{
      member: member,
      storage_id: storage_id,
      status: :ok,
      skipped_reason: nil,
      resumed: 0,
      reclaimed: 0,
      held_skipped: 0,
      deferred: 0,
      failed: 0,
      processed: 0
    }
  end

  defp emit_pass_telemetry(summary) do
    :telemetry.execute(
      @telemetry_event,
      %{
        resumed: summary.resumed,
        reclaimed: summary.reclaimed,
        held_skipped: summary.held_skipped,
        deferred: summary.deferred,
        failed: summary.failed,
        processed: summary.processed
      },
      %{
        member: summary.member,
        storage_id: summary.storage_id,
        status: summary.status,
        skipped_reason: summary.skipped_reason
      }
    )
  end
end
