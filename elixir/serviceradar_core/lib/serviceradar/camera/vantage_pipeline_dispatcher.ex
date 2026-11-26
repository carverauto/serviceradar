defmodule ServiceRadar.Camera.VantagePipelineDispatcher do
  @moduledoc """
  Relays pending and stale-expired `ServiceRadar.Camera.VantageJob` CNPG outbox
  rows to NATS JetStream (`CAMERA_MEDIA_JOBS`) with dynamic Ramp 1 <-> Ramp 2
  capability routing, `vantage.job.v1` envelope hydration, and bounded CAS
  concurrency safety.
  """

  import Ash.Expr

  alias Ash.Error.Changes.StaleRecord
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Camera.RecordingCatalogEntry
  alias ServiceRadar.Camera.VantageJob
  alias ServiceRadar.Camera.VantagePipeline
  alias ServiceRadar.Camera.VantagePipelineDispatchWorker
  alias ServiceRadar.Camera.VantageTriggerAdmitter
  alias ServiceRadar.Camera.VantageWorkerRegistration
  alias ServiceRadar.NATS.JetStreamPublish
  alias ServiceRadar.Observability.TripwireHealth

  require Ash.Query
  require Logger

  @jobs_stream "CAMERA_MEDIA_JOBS"
  @vlm_subject "media.jobs.vantage.vlm.v1"
  @default_batch_size 100
  @max_batch_size 500
  @max_relay_pages 10
  @max_envelope_bytes 4096
  @default_deadline_ms 30_000
  @max_deadline_ms 3_600_000
  @tripwire_check "camera_vantage_pipeline_dispatch"
  @error_class_regex ~r/\A[a-z0-9_:-]{1,64}\z/

  @default_crop_policy %{
    "padding_ratio" => 0.1,
    "min_bbox_width_px" => 32,
    "max_dimension" => 640,
    "max_bytes" => 98_304
  }

  @default_vlm_config %{
    "prompt" => "Inspect this camera frame and emit structured observations.",
    "model_profile" => "vlm_default",
    "max_tokens" => 256,
    "temperature" => 0.0
  }

  @system_actor SystemActor.system(:camera_vantage_pipeline_dispatcher)

  @doc """
  Whether Vantage ML pipeline relay is enabled for this deployment.
  """
  @spec deployment_enabled?((String.t(), String.t() -> String.t() | nil)) :: boolean()
  def deployment_enabled?(fetch \\ &System.get_env/2) when is_function(fetch, 2) do
    fetch.("SERVICERADAR_VANTAGE_PIPELINES_ENABLED", "false") == "true"
  end

  @doc "Tripwire health check identifier for terminal Vantage dispatch failures."
  @spec tripwire_check_id() :: String.t()
  def tripwire_check_id, do: @tripwire_check

  @doc "NATS JetStream subject for a capability or `camera_vlm` runner."
  @spec job_subject(atom(), String.t() | nil, :live | :backfill) :: String.t()
  defdelegate job_subject(runner, capability, job_kind), to: VantageTriggerAdmitter

  @doc "Normalizes a capability string into a NATS subject slug."
  @spec capability_slug(String.t()) :: String.t()
  defdelegate capability_slug(capability), to: VantageTriggerAdmitter

  @doc """
  Best-effort immediate nudge of `VantagePipelineDispatchWorker` so newly
  admitted jobs relay promptly without waiting for the 1-minute cron tick.
  """
  @spec nudge_dispatch(keyword()) :: :ok
  def nudge_dispatch(opts \\ []) when is_list(opts) do
    enqueuer = Keyword.get(opts, :dispatch_enqueuer)

    result =
      if is_function(enqueuer, 0) do
        enqueuer.()
      else
        VantagePipelineDispatchWorker.enqueue(Keyword.take(opts, [:enabled_fn, :insert_fn]))
      end

    case result do
      {:error, reason} ->
        Logger.warning(
          "Vantage pipeline immediate dispatch nudge failed; cron safety net will relay",
          reason: inspect(reason)
        )

      _ ->
        :ok
    end

    :ok
  end

  @doc """
  Queries active, ready, unsaturated worker registrations supporting
  `capability` and `source_mode` at `now`.
  """
  @spec eligible_workers(String.t(), atom() | String.t(), DateTime.t(), keyword()) ::
          {:ok, [map()]} | {:error, term()}
  def eligible_workers(capability, source_mode, now \\ DateTime.utc_now(), opts \\ [])
      when is_binary(capability) and is_list(opts) do
    source_mode_str = to_string(source_mode)

    raw_result =
      cond do
        Keyword.has_key?(opts, :workers) ->
          {:ok, List.wrap(Keyword.get(opts, :workers, []))}

        is_function(opts[:workers_loader], 3) ->
          opts[:workers_loader].(capability, source_mode_str, now)

        is_function(opts[:workers_loader], 0) ->
          opts[:workers_loader].()

        true ->
          VantageWorkerRegistration.eligible_for_dispatch(capability, source_mode_str, now,
            actor: @system_actor
          )
      end

    case raw_result do
      {:ok, workers} when is_list(workers) ->
        {:ok, Enum.filter(workers, &worker_eligible?(&1, capability, source_mode_str, now))}

      workers when is_list(workers) ->
        {:ok, Enum.filter(workers, &worker_eligible?(&1, capability, source_mode_str, now))}

      {:error, _} = err ->
        err

      other ->
        {:error, {:invalid_workers_response, other}}
    end
  end

  @doc """
  Resolves the live Ramp 1 (`camera_vlm`) <-> Ramp 2 (`vantage.worker.v1`)
  route for `pipeline` and `job_kind` at `now`.
  """
  @spec resolve_route(map(), atom() | String.t(), DateTime.t(), keyword()) ::
          {:dispatch,
           %{
             target_runner: String.t(),
             subject: String.t(),
             runner_kind: :camera_vlm | :external_worker,
             capability: String.t(),
             fallback?: boolean()
           }}
          | {:hold, :no_eligible_worker}
  def resolve_route(pipeline, job_kind \\ :live, now \\ DateTime.utc_now(), opts \\ [])
      when is_map(pipeline) and is_list(opts) do
    runner = normalize_runner(fetch_val(pipeline, :runner))
    source_mode = normalize_source_mode(fetch_val(pipeline, :source_mode))
    kind = normalize_job_kind(job_kind)
    capability = normalize_capability(fetch_val(pipeline, :capability), runner)
    fallback = normalize_optional_runner(fetch_val(pipeline, :fallback_runner))

    case runner do
      :camera_vlm ->
        {:dispatch,
         %{
           target_runner: "camera_vlm",
           subject: job_subject(:camera_vlm, nil, kind),
           runner_kind: :camera_vlm,
           capability: capability,
           fallback?: false
         }}

      :external_worker ->
        if external_worker_eligible?(capability, source_mode, now, opts) do
          {:dispatch,
           %{
             target_runner: capability,
             subject: job_subject(:external_worker, capability, kind),
             runner_kind: :external_worker,
             capability: capability,
             fallback?: false
           }}
        else
          if fallback == "camera_vlm" and source_mode == :recorded_block do
            {:dispatch,
             %{
               target_runner: "camera_vlm",
               subject: job_subject(:camera_vlm, nil, kind),
               runner_kind: :camera_vlm,
               capability: capability,
               fallback?: true
             }}
          else
            {:hold, :no_eligible_worker}
          end
        end
    end
  end

  @doc """
  Builds and validates the bounded (`<= 4096` bytes) `vantage.job.v1` JSON wire
  envelope for `job` and optional `pipeline`.
  """
  @spec build_envelope(map(), map() | nil, keyword()) ::
          {:ok, String.t(), binary(), map()} | {:error, term()}
  def build_envelope(job, pipeline \\ nil, opts \\ []) when is_map(job) and is_list(opts) do
    stored_payload = ensure_map(fetch_val(job, :job_payload))

    target_runner =
      Keyword.get(opts, :target_runner) ||
        fetch_val(job, :target_runner) ||
        "camera_vlm"

    subject =
      Keyword.get(opts, :subject) ||
        fetch_val(job, :subject) ||
        @vlm_subject

    source_mode =
      pipeline_or_payload_source_mode(pipeline, stored_payload)

    input_mode =
      pipeline_or_payload_input_mode(pipeline, stored_payload)

    capability =
      resolve_envelope_capability(pipeline, stored_payload, target_runner)

    time_basis =
      opts
      |> Keyword.get(:time_basis)
      |> normalize_time_basis(fetch_val(stored_payload, :time_basis))

    roi_polygons =
      normalize_roi_polygons(
        fetch_val(pipeline || %{}, :roi_polygons) || fetch_val(stored_payload, :roi_polygons) ||
          []
      )

    crop_policy =
      normalize_crop_policy(
        fetch_val(pipeline || %{}, :crop_policy) || fetch_val(stored_payload, :crop_policy)
      )

    raw_targets = List.wrap(fetch_val(job, :sampled_targets) || [])

    sampled_targets =
      Enum.map(raw_targets, &normalize_sampled_target(&1, input_mode, time_basis))

    base_envelope =
      maybe_put_vlm_config(
        %{
          "schema_version" => "vantage.job.v1",
          "job_id" => to_string(fetch_val(job, :id)),
          "pack_id" =>
            fetch_val(pipeline || %{}, :pack_id) || fetch_val(stored_payload, :pack_id),
          "pipeline_id" => to_string(fetch_val(job, :pipeline_id)),
          "pipeline_version" => to_string(fetch_val(job, :pipeline_version)),
          "capability" => capability,
          "source_mode" => source_mode,
          "camera_source_id" => to_string(fetch_val(job, :camera_source_id)),
          "stream_profile_id" => to_string(fetch_val(job, :stream_profile_id)),
          "catalog_entry_id" => maybe_string_id(fetch_val(job, :catalog_entry_id)),
          "descriptor_sha256" => maybe_string(fetch_val(job, :descriptor_sha256)),
          "input_mode" => input_mode,
          "roi_polygons" => roi_polygons,
          "crop_policy" => crop_policy,
          "sampled_targets" => sampled_targets,
          "signal_schema_id" =>
            non_empty_str(
              fetch_val(pipeline || %{}, :signal_schema_id) ||
                fetch_val(stored_payload, :signal_schema_id),
              "vlm_narrative_event"
            ),
          "signal_schema_version" =>
            non_empty_str(
              fetch_val(pipeline || %{}, :signal_schema_version) ||
                fetch_val(stored_payload, :signal_schema_version),
              "1.0.0"
            ),
          "display_contract_id" =>
            non_empty_str(
              fetch_val(pipeline || %{}, :display_contract_id) ||
                fetch_val(stored_payload, :display_contract_id),
              "vlm_narrative_event"
            ),
          "budget_ms" =>
            positive_int(
              fetch_val(pipeline || %{}, :budget_ms) || fetch_val(stored_payload, :budget_ms),
              5000
            ),
          "pipeline_config" =>
            Map.merge(
              ensure_map(fetch_val(stored_payload, :pipeline_config)),
              VantagePipeline.effective_pipeline_config(pipeline)
            )
        },
        pipeline,
        stored_payload,
        target_runner
      )

    case fit_envelope_budget(base_envelope) do
      {:ok, bounded_envelope, encoded} ->
        {:ok, subject, encoded, bounded_envelope}

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Executes one relay pass: reconciles expired `:dispatched` jobs first (so stale
  workers recover or fall back promptly), then dispatches `:pending` jobs.
  """
  @spec relay(keyword()) :: {:ok, map()} | {:error, term()}
  def relay(opts \\ []) when is_list(opts) do
    if enabled?(opts) do
      now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)

      batch_size =
        clamp_int(Keyword.get(opts, :batch_size, @default_batch_size), 1, @max_batch_size)

      with {:ok, expired_summary, held_pipelines, unavailable_entries} <-
             reconcile_expired_dispatched_jobs_with_holds(now, batch_size, opts),
           {:ok, pending_summary} <-
             dispatch_pending_jobs_with_holds(
               now,
               batch_size,
               held_pipelines,
               unavailable_entries,
               opts
             ) do
        {:ok, merge_summaries(expired_summary, pending_summary)}
      end
    else
      {:ok, empty_summary()}
    end
  end

  @doc """
  Reconciles `:dispatched` jobs whose `deadline_at <= now`.
  """

  # ---------------------------------------------------------------------------
  # Private dispatch & reconciliation
  # ---------------------------------------------------------------------------

  @spec reconcile_expired_dispatched_jobs(DateTime.t(), pos_integer(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def reconcile_expired_dispatched_jobs(now, batch_size, opts) do
    with {:ok, summary, _held_pipelines, _unavailable_entries} <-
           reconcile_expired_dispatched_jobs_with_holds(now, batch_size, opts) do
      {:ok, summary}
    end
  end

  @doc """
  Dispatches `:pending` `VantageJob` rows using live worker capability routing.
  """
  @spec dispatch_pending_jobs(DateTime.t(), pos_integer(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def dispatch_pending_jobs(now, batch_size, opts) do
    dispatch_pending_jobs_with_holds(now, batch_size, MapSet.new(), MapSet.new(), opts)
  end

  defp reconcile_expired_dispatched_jobs_with_holds(now, batch_size, opts) do
    initial = %{
      summary: empty_summary(),
      actionable_count: 0,
      held_pipelines: MapSet.new(),
      held_pipeline_reasons: %{},
      unavailable_entries: MapSet.new()
    }

    result =
      case expired_jobs_mode(opts) do
        {:single_list, loader_fn} ->
          with {:ok, jobs} <- loader_fn.(now, batch_size) do
            sorted =
              Enum.sort_by(jobs, fn job ->
                {kind_priority(job), datetime_sort_key(fetch_val(job, :deadline_at)),
                 to_string(fetch_val(job, :id))}
              end)

            {:ok, reduce_expired_jobs(sorted, batch_size, now, initial, opts)}
          end

        :paginated ->
          run_paginated_phase(
            [:live, :backfill],
            batch_size,
            initial,
            fn kind, page_limit, cursor, state ->
              filter_opts = [
                job_kind: kind,
                cursor: cursor,
                exclude_pipelines: state.held_pipelines,
                exclude_catalog_entries: state.unavailable_entries
              ]

              load_expired_dispatched_jobs_page(now, page_limit, filter_opts, opts)
            end,
            fn jobs, state -> reduce_expired_jobs(jobs, batch_size, now, state, opts) end,
            fn job -> {fetch_val(job, :deadline_at), fetch_val(job, :id)} end
          )
      end

    with {:ok, final_state} <- result do
      {:ok, final_state.summary, final_state.held_pipelines, final_state.unavailable_entries}
    end
  end

  defp dispatch_pending_jobs_with_holds(
         now,
         batch_size,
         held_pipelines,
         unavailable_entries,
         opts
       ) do
    initial = %{
      summary: empty_summary(),
      actionable_count: 0,
      held_pipelines: held_pipelines,
      unavailable_entries: unavailable_entries
    }

    result =
      case pending_jobs_mode(opts) do
        {:single_list, loader_fn} ->
          with {:ok, jobs} <- loader_fn.(batch_size) do
            filtered =
              jobs
              |> Enum.reject(fn job ->
                MapSet.member?(held_pipelines, pipeline_key(job)) or
                  unavailable_entry?(job, unavailable_entries)
              end)
              |> Enum.sort_by(fn job ->
                {kind_priority(job), datetime_sort_key(fetch_val(job, :inserted_at)),
                 to_string(fetch_val(job, :id))}
              end)

            {:ok, reduce_pending_jobs(filtered, batch_size, now, initial, opts)}
          end

        :paginated ->
          run_paginated_phase(
            [:live, :backfill],
            batch_size,
            initial,
            fn kind, page_limit, cursor, state ->
              filter_opts = [
                job_kind: kind,
                cursor: cursor,
                exclude_pipelines: state.held_pipelines,
                exclude_catalog_entries: state.unavailable_entries
              ]

              load_pending_jobs_page(page_limit, filter_opts, opts)
            end,
            fn jobs, state -> reduce_pending_jobs(jobs, batch_size, now, state, opts) end,
            fn job -> {fetch_val(job, :inserted_at), fetch_val(job, :id)} end
          )
      end

    with {:ok, final_state} <- result do
      {:ok, final_state.summary}
    end
  end

  defp run_paginated_phase(kinds, batch_size, initial_state, fetch_page_fn, reduce_fn, cursor_fn) do
    Enum.reduce_while(kinds, {:ok, initial_state}, fn kind, {:ok, state} ->
      if state.actionable_count >= batch_size do
        {:halt, {:ok, state}}
      else
        case paginate_kind(kind, batch_size, state, nil, 1, fetch_page_fn, reduce_fn, cursor_fn) do
          {:ok, next_state} -> {:cont, {:ok, next_state}}
          {:error, _} = err -> {:halt, err}
        end
      end
    end)
  end

  defp paginate_kind(
         _kind,
         _batch_size,
         state,
         _cursor,
         page_num,
         _fetch_fn,
         _reduce_fn,
         _cursor_fn
       )
       when page_num > @max_relay_pages do
    {:ok, state}
  end

  defp paginate_kind(kind, batch_size, state, cursor, page_num, fetch_fn, reduce_fn, cursor_fn) do
    page_limit = max(1, batch_size - state.actionable_count)

    case fetch_fn.(kind, page_limit, cursor, state) do
      {:ok, []} ->
        {:ok, state}

      {:ok, jobs} when is_list(jobs) ->
        next_state = reduce_fn.(jobs, state)

        cond do
          next_state.actionable_count >= batch_size ->
            {:ok, next_state}

          length(jobs) < page_limit ->
            {:ok, next_state}

          true ->
            next_cursor = cursor_fn.(List.last(jobs))

            if next_cursor == cursor do
              {:ok, next_state}
            else
              paginate_kind(
                kind,
                batch_size,
                next_state,
                next_cursor,
                page_num + 1,
                fetch_fn,
                reduce_fn,
                cursor_fn
              )
            end
        end

      {:error, _} = err ->
        err
    end
  end

  defp reduce_expired_jobs(jobs, batch_size, now, initial_state, opts) do
    Enum.reduce_while(jobs, initial_state, fn job, state ->
      if state.actionable_count >= batch_size do
        {:halt, state}
      else
        next_state = process_expired_job(job, now, state, opts)
        {:cont, next_state}
      end
    end)
  end

  defp process_expired_job(job, now, state, opts) do
    p_key = pipeline_key(job)
    cached_reason = Map.get(state.held_pipeline_reasons, p_key)

    outcome =
      if is_binary(cached_reason) do
        case check_catalog_availability(job, opts) do
          {:ok, :recording_gone, _entry} ->
            cancel_job_cas(job, "recording_gone", opts)

          {:ok, :recording_unavailable, _entry} ->
            requeue_pending_with_reason(job, "recording_unavailable", opts)

          {:ok, :playable, _entry} ->
            attempt_count = fetch_val(job, :attempt_count) || 0
            max_attempts = fetch_val(job, :max_attempts) || 5

            if attempt_count >= max_attempts do
              fail_terminal_cas(job, "max_deliver_exhausted", opts)
            else
              requeue_pending_with_reason(job, cached_reason, opts)
            end

          {:error, _} = err ->
            err
        end
      else
        reconcile_one_expired_job(job, now, opts)
      end

    apply_job_outcome(state, job, outcome)
  end

  defp reduce_pending_jobs(jobs, batch_size, now, initial_state, opts) do
    Enum.reduce_while(jobs, initial_state, fn job, state ->
      if state.actionable_count >= batch_size do
        {:halt, state}
      else
        next_state = process_pending_job(job, now, state, opts)
        {:cont, next_state}
      end
    end)
  end

  defp process_pending_job(job, now, state, opts) do
    p_key = pipeline_key(job)

    outcome =
      cond do
        MapSet.member?(state.held_pipelines, p_key) ->
          {:ok, :held, "no_eligible_worker"}

        unavailable_entry?(job, state.unavailable_entries) ->
          {:ok, :held, "recording_unavailable"}

        true ->
          dispatch_one_pending_job(job, now, opts)
      end

    apply_job_outcome(state, job, outcome)
  end

  defp apply_job_outcome(state, job, {:ok, :held, reason}) do
    state = %{state | summary: bump_summary(state.summary, :held)}

    case reason do
      "recording_unavailable" ->
        case fetch_val(job, :catalog_entry_id) do
          nil ->
            state

          entry_id ->
            %{state | unavailable_entries: MapSet.put(state.unavailable_entries, entry_id)}
        end

      other when other in ["no_eligible_worker", "pipeline_disabled"] ->
        p_key = pipeline_key(job)

        state = %{state | held_pipelines: MapSet.put(state.held_pipelines, p_key)}

        if Map.has_key?(state, :held_pipeline_reasons) do
          %{state | held_pipeline_reasons: Map.put(state.held_pipeline_reasons, p_key, other)}
        else
          state
        end

      _ ->
        state
    end
  end

  defp apply_job_outcome(state, _job, {:ok, outcome})
       when outcome in [:dispatched, :cancelled, :failed_terminal, :superseded] do
    %{
      state
      | summary: bump_summary(state.summary, outcome),
        actionable_count: state.actionable_count + 1
    }
  end

  defp apply_job_outcome(state, _job, {:ok, outcome}) do
    %{state | summary: bump_summary(state.summary, outcome)}
  end

  defp apply_job_outcome(state, _job, {:error, reason}) do
    %{state | summary: record_error_outcome(state.summary, reason)}
  end

  @doc """
  Dispatches or reconciles a single `VantageJob` using live routing and CAS
  state transition guards.
  """
  @spec dispatch_job(map(), keyword()) ::
          {:ok, :dispatched | :held | :cancelled | :failed_terminal | :skipped}
          | {:error, term()}
  def dispatch_job(job, opts \\ []) when is_map(job) and is_list(opts) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)

    result =
      case fetch_val(job, :state) do
        s when s in [:pending, "pending"] -> dispatch_one_pending_job(job, now, opts)
        s when s in [:dispatched, "dispatched"] -> reconcile_one_expired_job(job, now, opts)
        _ -> {:ok, :skipped}
      end

    case result do
      {:ok, :held, _reason} -> {:ok, :held}
      other -> other
    end
  end

  defp dispatch_one_pending_job(job, now, opts) do
    case check_catalog_availability(job, opts) do
      {:ok, :recording_gone, _entry} ->
        cancel_job_cas(job, "recording_gone", opts)

      {:ok, :recording_unavailable, _entry} ->
        {:ok, :held, "recording_unavailable"}

      {:ok, :playable, entry} ->
        attempt_count = fetch_val(job, :attempt_count) || 0
        max_attempts = fetch_val(job, :max_attempts) || 5

        if attempt_count >= max_attempts do
          fail_terminal_cas(job, "max_deliver_exhausted", opts)
        else
          route_and_publish(job, entry, now, opts)
        end

      {:error, _} = err ->
        err
    end
  end

  defp reconcile_one_expired_job(job, now, opts) do
    case check_catalog_availability(job, opts) do
      {:ok, :recording_gone, _entry} ->
        cancel_job_cas(job, "recording_gone", opts)

      {:ok, :recording_unavailable, _entry} ->
        requeue_pending_with_reason(job, "recording_unavailable", opts)

      {:ok, :playable, entry} ->
        attempt_count = fetch_val(job, :attempt_count) || 0
        max_attempts = fetch_val(job, :max_attempts) || 5

        if attempt_count >= max_attempts do
          fail_terminal_cas(job, "max_deliver_exhausted", opts)
        else
          case route_and_publish(job, entry, now, opts) do
            {:ok, :held, reason} -> requeue_pending_with_reason(job, reason, opts)
            other -> other
          end
        end

      {:error, _} = err ->
        err
    end
  end

  defp route_and_publish(job, entry, now, opts) do
    pipeline = resolve_pipeline(job, opts)

    if pipeline != nil and fetch_val(pipeline, :enabled) == false do
      {:ok, :held, "pipeline_disabled"}
    else
      routing_input = pipeline || synthetic_pipeline_from_job(job)

      case resolve_route(routing_input, fetch_val(job, :job_kind), now, opts) do
        {:hold, :no_eligible_worker} ->
          {:ok, :held, "no_eligible_worker"}

        {:dispatch, route} ->
          publish_and_mark_dispatched(job, pipeline, entry, route, now, opts)
      end
    end
  end

  defp publish_and_mark_dispatched(job, pipeline, entry, route, now, opts) do
    budget_ms =
      positive_int(
        fetch_val(pipeline || %{}, :budget_ms) ||
          get_in(ensure_map(fetch_val(job, :job_payload)), ["budget_ms"]),
        @default_deadline_ms
      )

    default_window_ms = max(@default_deadline_ms, budget_ms * 2)

    deadline_ms =
      opts
      |> Keyword.get(:deadline_ms, default_window_ms)
      |> clamp_int(1_000, @max_deadline_ms)

    deadline_at = DateTime.add(now, deadline_ms, :millisecond)

    envelope_opts =
      opts
      |> Keyword.put(:target_runner, route.target_runner)
      |> Keyword.put(:subject, route.subject)
      |> maybe_put_time_basis(entry)

    case build_envelope(job, pipeline, envelope_opts) do
      {:ok, subject, encoded, _payload} ->
        msg_id = build_msg_id(job)

        with :ok <- publish(subject, encoded, msg_id, opts) do
          mark_dispatched_cas(job, route, now, deadline_at, opts)
        end

      {:error, :envelope_too_large} ->
        fail_terminal_cas(job, "envelope_too_large", opts)

      {:error, _} = err ->
        err
    end
  end

  defp requeue_pending_with_reason(job, reason, opts) do
    case requeue_pending_cas(job, reason, opts) do
      {:ok, :held} -> {:ok, :held, reason}
      other -> other
    end
  end

  defp requeue_pending_cas(job, reason, opts) do
    read_state = normalize_state_atom(fetch_val(job, :state))
    read_attempt = fetch_val(job, :attempt_count) || 0
    error_class = normalize_error_class(reason)

    case Keyword.get(opts, :mark_pending_fn) do
      fun when is_function(fun, 4) ->
        normalize_cas_result(fun.(job, error_class, read_state, read_attempt), :held)

      _ ->
        job
        |> Ash.Changeset.for_update(:requeue_pending, %{last_error_class: error_class})
        |> Ash.Changeset.filter(expr(state == ^read_state and attempt_count == ^read_attempt))
        |> Ash.update(actor: @system_actor)
        |> superseded_when_stale()
        |> normalize_cas_result(:held)
    end
  end

  defp mark_dispatched_cas(job, route, now, deadline_at, opts) do
    read_state = normalize_state_atom(fetch_val(job, :state))
    read_attempt = fetch_val(job, :attempt_count) || 0

    attrs = %{
      dispatched_at: now,
      deadline_at: deadline_at,
      last_error_class: nil,
      target_runner: route.target_runner,
      subject: route.subject
    }

    case Keyword.get(opts, :mark_dispatched_fn) do
      fun when is_function(fun, 4) ->
        normalize_cas_result(fun.(job, attrs, read_state, read_attempt), :dispatched)

      _ ->
        job
        |> Ash.Changeset.for_update(:mark_dispatched, attrs)
        |> Ash.Changeset.filter(expr(state == ^read_state and attempt_count == ^read_attempt))
        |> Ash.update(actor: @system_actor)
        |> superseded_when_stale()
        |> normalize_cas_result(:dispatched)
    end
  end

  defp cancel_job_cas(job, reason, opts) do
    read_state = normalize_state_atom(fetch_val(job, :state))
    read_attempt = fetch_val(job, :attempt_count) || 0
    error_class = normalize_error_class(reason)

    case Keyword.get(opts, :mark_cancelled_fn) do
      fun when is_function(fun, 4) ->
        normalize_cas_result(fun.(job, error_class, read_state, read_attempt), :cancelled)

      _ ->
        job
        |> Ash.Changeset.for_update(:mark_cancelled, %{last_error_class: error_class})
        |> Ash.Changeset.filter(expr(state == ^read_state and attempt_count == ^read_attempt))
        |> Ash.update(actor: @system_actor)
        |> superseded_when_stale()
        |> normalize_cas_result(:cancelled)
    end
  end

  defp fail_terminal_cas(job, reason, opts) do
    read_state = normalize_state_atom(fetch_val(job, :state))
    read_attempt = fetch_val(job, :attempt_count) || 0
    error_class = normalize_error_class(reason)

    result =
      case Keyword.get(opts, :mark_failed_terminal_fn) do
        fun when is_function(fun, 4) ->
          fun.(job, error_class, read_state, read_attempt)

        _ ->
          job
          |> Ash.Changeset.for_update(:mark_failed_terminal, %{last_error_class: error_class})
          # ---------------------------------------------------------------------------
          # Envelope normalization & 4 KiB budget enforcement
          # ---------------------------------------------------------------------------
          |> Ash.Changeset.filter(expr(state == ^read_state and attempt_count == ^read_attempt))
          |> Ash.update(actor: @system_actor)
          |> superseded_when_stale()
      end

    case normalize_cas_result(result, :failed_terminal) do
      {:ok, :failed_terminal} = ok ->
        record_terminal_tripwire(job, error_class, opts)
        ok

      other ->
        other
    end
  end

  defp record_terminal_tripwire(job, error_class, opts) do
    metadata = %{
      "job_id" => to_string(fetch_val(job, :id)),
      "pipeline_id" => to_string(fetch_val(job, :pipeline_id)),
      "catalog_entry_id" => maybe_string_id(fetch_val(job, :catalog_entry_id)),
      "error_class" => error_class
    }

    case Keyword.get(opts, :tripwire_fn) do
      fun when is_function(fun, 3) ->
        fun.(@tripwire_check, false, metadata)

      _ ->
        TripwireHealth.record(@tripwire_check, false, metadata, refresh_metadata: true)
    end
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp normalize_cas_result({:ok, _}, outcome), do: {:ok, outcome}
  defp normalize_cas_result({:error, :dispatch_superseded}, _outcome), do: {:ok, :superseded}
  defp normalize_cas_result({:error, _} = err, _outcome), do: err

  defp superseded_when_stale({:error, %Ash.Error.Invalid{errors: errors}} = error) do
    if Enum.any?(errors, &match?(%StaleRecord{}, &1)),
      do: {:error, :dispatch_superseded},
      else: error
  end

  defp superseded_when_stale(result), do: result

  defp publish(subject, encoded, msg_id, opts) do
    publisher = Keyword.get(opts, :publisher, &JetStreamPublish.publish_acked/3)
    headers = [{"Nats-Expected-Stream", @jobs_stream}]

    case publisher.(subject, encoded, msg_id: msg_id, headers: headers) do
      {:ok, %{stream: @jobs_stream, seq: seq}} when is_integer(seq) and seq > 0 -> :ok
      {:error, reason} -> {:error, {:publish_failed, reason}}
      other -> {:error, {:publish_failed, {:invalid_puback, other}}}
    end
  end

  defp build_msg_id(job) do
    attempt = fetch_val(job, :attempt_count) || 0
    "vantage-job:#{fetch_val(job, :id)}:#{attempt}"
  end

  defp fit_envelope_budget(envelope) do
    encoded = Jason.encode!(envelope)

    if byte_size(encoded) <= @max_envelope_bytes do
      {:ok, envelope, encoded}
    else
      trim_targets_to_budget(envelope)
    end
  end

  defp trim_targets_to_budget(%{"sampled_targets" => targets} = envelope)
       when length(targets) > 1 do
    # Keep distinct fragment_sequence samples evenly first when trimming oversized target arrays.
    deduped = Enum.uniq_by(targets, &Map.get(&1, "fragment_sequence"))

    candidate_lists =
      [deduped] ++
        for n <- (length(targets) - 1)..1//-1 do
          Enum.take(deduped, n)
        end

    Enum.find_value(candidate_lists, {:error, :envelope_too_large}, fn sliced ->
      if sliced != [] do
        candidate = Map.put(envelope, "sampled_targets", sliced)
        encoded = Jason.encode!(candidate)

        if byte_size(encoded) <= @max_envelope_bytes do
          {:ok, candidate, encoded}
        end
      end
    end)
  end

  defp trim_targets_to_budget(_envelope), do: {:error, :envelope_too_large}

  defp normalize_roi_polygons(polygons) when is_list(polygons) do
    Enum.flat_map(polygons, fn
      %{"points" => pts} -> normalize_single_polygon(pts)
      %{points: pts} -> normalize_single_polygon(pts)
      pts when is_list(pts) -> normalize_single_polygon(pts)
      _ -> []
    end)
  end

  defp normalize_roi_polygons(_), do: []

  defp normalize_single_polygon(pts) when is_list(pts) do
    parsed =
      Enum.flat_map(pts, fn
        [x, y] when is_number(x) and is_number(y) ->
          [[clamp_unit(x), clamp_unit(y)]]

        %{"x" => x, "y" => y} when is_number(x) and is_number(y) ->
          [[clamp_unit(x), clamp_unit(y)]]

        %{x: x, y: y} when is_number(x) and is_number(y) ->
          [[clamp_unit(x), clamp_unit(y)]]

        _ ->
          []
      end)

    if length(parsed) >= 3, do: [parsed], else: []
  end

  defp normalize_single_polygon(_), do: []

  defp normalize_crop_policy(policy) when is_map(policy) do
    %{
      "padding_ratio" =>
        non_neg_float(fetch_val(policy, :padding_ratio), @default_crop_policy["padding_ratio"]),
      "min_bbox_width_px" =>
        positive_int(
          fetch_val(policy, :min_bbox_width_px),
          @default_crop_policy["min_bbox_width_px"]
        ),
      "max_dimension" =>
        clamp_int(
          fetch_val(policy, :max_dimension) || @default_crop_policy["max_dimension"],
          1,
          640
        ),
      "max_bytes" =>
        clamp_int(
          fetch_val(policy, :max_bytes) || @default_crop_policy["max_bytes"],
          512,
          98_304
        )
    }
  end

  defp normalize_crop_policy(_), do: @default_crop_policy

  defp normalize_sampled_target(target, input_mode, default_time_basis) when is_map(target) do
    target_key = non_empty_str(fetch_val(target, :target_key), "block")
    frag_seq = non_neg_int(fetch_val(target, :fragment_sequence), 0)
    pts_ns = non_neg_int(fetch_val(target, :media_pts_ns), 0)
    timeline_ts_us = non_neg_int(fetch_val(target, :timeline_ts_us), 0)

    time_basis =
      normalize_time_basis(fetch_val(target, :time_basis), default_time_basis)

    base = %{
      "target_key" => target_key,
      "fragment_sequence" => frag_seq,
      "media_pts_ns" => pts_ns,
      "timeline_ts_us" => timeline_ts_us,
      "time_basis" => time_basis
    }

    if input_mode == "full_frame" do
      base
      |> Map.put("track_id", non_empty_str(fetch_val(target, :track_id), target_key))
      |> Map.put("category", non_empty_str(fetch_val(target, :category), "frame"))
      |> Map.put("confidence", unit_float(fetch_val(target, :confidence), 1.0))
      |> Map.put("bbox", normalize_bbox(fetch_val(target, :bbox), [0.0, 0.0, 1.0, 1.0]))
    else
      base
      |> Map.put("track_id", non_empty_str(fetch_val(target, :track_id), target_key))
      |> Map.put("category", non_empty_str(fetch_val(target, :category), "object"))
      |> Map.put("confidence", unit_float(fetch_val(target, :confidence), 0.5))
      |> Map.put("bbox", normalize_bbox(fetch_val(target, :bbox), [0.0, 0.0, 1.0, 1.0]))
    end
  end

  defp normalize_sampled_target(_, _input_mode, default_time_basis) do
    %{
      "target_key" => "block",
      "track_id" => "block",
      "fragment_sequence" => 0,
      "media_pts_ns" => 0,
      "timeline_ts_us" => 0,
      "time_basis" => default_time_basis,
      "category" => "frame",
      "confidence" => 1.0,
      "bbox" => [0.0, 0.0, 1.0, 1.0]
    }
  end

  defp normalize_bbox([x1, y1, x2, y2], _fallback)
       when is_number(x1) and is_number(y1) and is_number(x2) and is_number(y2) do
    cx1 = clamp_unit(x1)
    cy1 = clamp_unit(y1)
    cx2 = clamp_unit(x2)
    cy2 = clamp_unit(y2)

    if cx1 < cx2 and cy1 < cy2, do: [cx1, cy1, cx2, cy2], else: [0.0, 0.0, 1.0, 1.0]
  end

  defp normalize_bbox(%{"x1" => x1, "y1" => y1, "x2" => x2, "y2" => y2}, fallback) do
    normalize_bbox([x1, y1, x2, y2], fallback)
  end

  defp normalize_bbox(%{x1: x1, y1: y1, x2: x2, y2: y2}, fallback) do
    normalize_bbox([x1, y1, x2, y2], fallback)
  end

  defp normalize_bbox(_, fallback), do: fallback

  defp maybe_put_vlm_config(envelope, pipeline, stored_payload, target_runner) do
    raw_vlm =
      ensure_map(
        fetch_val(pipeline || %{}, :vlm_config) || fetch_val(stored_payload, :vlm_config)
      )

    if target_runner == "camera_vlm" do
      vlm = %{
        "prompt" => non_empty_str(fetch_val(raw_vlm, :prompt), @default_vlm_config["prompt"]),
        "model_profile" =>
          non_empty_str(
            fetch_val(raw_vlm, :model_profile),
            # ---------------------------------------------------------------------------
            # Loaders & Eligibility
            # ---------------------------------------------------------------------------
            @default_vlm_config["model_profile"]
          ),
        "max_tokens" =>
          positive_int(fetch_val(raw_vlm, :max_tokens), @default_vlm_config["max_tokens"]),
        "temperature" =>
          clamp_float(
            fetch_val(raw_vlm, :temperature),
            0.0,
            2.0,
            @default_vlm_config["temperature"]
          )
      }

      Map.put(envelope, "vlm_config", vlm)
    else
      if map_size(raw_vlm) == 0 do
        envelope
      else
        vlm = %{
          "prompt" => non_empty_str(fetch_val(raw_vlm, :prompt), @default_vlm_config["prompt"]),
          "model_profile" =>
            non_empty_str(
              fetch_val(raw_vlm, :model_profile),
              @default_vlm_config["model_profile"]
            ),
          "max_tokens" =>
            positive_int(fetch_val(raw_vlm, :max_tokens), @default_vlm_config["max_tokens"]),
          "temperature" =>
            clamp_float(
              fetch_val(raw_vlm, :temperature),
              0.0,
              2.0,
              @default_vlm_config["temperature"]
            )
        }

        Map.put(envelope, "vlm_config", vlm)
      end
    end
  end

  defp resolve_envelope_capability(pipeline, stored_payload, target_runner) do
    cond do
      is_binary(fetch_val(pipeline || %{}, :capability)) and
          String.trim(fetch_val(pipeline || %{}, :capability)) != "" ->
        String.trim(fetch_val(pipeline || %{}, :capability))

      is_binary(fetch_val(stored_payload, :capability)) and
          String.trim(fetch_val(stored_payload, :capability)) != "" ->
        String.trim(fetch_val(stored_payload, :capability))

      is_binary(target_runner) and String.contains?(target_runner, ".") ->
        target_runner

      true ->
        "vantage.vlm.v1"
    end
  end

  defp pipeline_or_payload_source_mode(pipeline, stored_payload) do
    raw =
      fetch_val(pipeline || %{}, :source_mode) ||
        fetch_val(stored_payload, :source_mode) ||
        "recorded_block"

    case to_string(raw) do
      "live_keyframe_tap" -> "live_keyframe_tap"
      _ -> "recorded_block"
    end
  end

  defp pipeline_or_payload_input_mode(pipeline, stored_payload) do
    raw =
      fetch_val(pipeline || %{}, :input_mode) ||
        fetch_val(stored_payload, :input_mode) ||
        "detection_crop"

    case to_string(raw) do
      "full_frame" -> "full_frame"
      "multi_frame_track" -> "multi_frame_track"
      _ -> "detection_crop"
    end
  end

  defp pending_jobs_mode(opts) do
    loaders = Keyword.get(opts, :loaders, %{})
    loader = Map.get(loaders, :pending_jobs_loader)

    cond do
      is_function(loader, 2) ->
        :paginated

      is_function(loader, 1) ->
        {:single_list, loader}

      Keyword.has_key?(opts, :pending_jobs) ->
        {:single_list, fn _limit -> {:ok, List.wrap(Keyword.get(opts, :pending_jobs, []))} end}

      true ->
        :paginated
    end
  end

  defp expired_jobs_mode(opts) do
    loaders = Keyword.get(opts, :loaders, %{})
    loader = Map.get(loaders, :expired_jobs_loader)

    cond do
      is_function(loader, 3) ->
        :paginated

      is_function(loader, 2) ->
        {:single_list, loader}

      Keyword.has_key?(opts, :expired_jobs) ->
        {:single_list,
         fn now, _limit ->
           {:ok,
            opts
            |> Keyword.get(:expired_jobs, [])
            |> Enum.filter(fn job ->
              case fetch_val(job, :deadline_at) do
                %DateTime{} = dl -> DateTime.compare(dl, now) != :gt
                _ -> false
              end
            end)}
         end}

      true ->
        :paginated
    end
  end

  defp load_pending_jobs_page(page_limit, filter_opts, opts) do
    loaders = Keyword.get(opts, :loaders, %{})

    case Map.get(loaders, :pending_jobs_loader) do
      fun when is_function(fun, 2) ->
        fun.(page_limit, filter_opts)

      _ ->
        job_kind = Keyword.fetch!(filter_opts, :job_kind)
        cursor = Keyword.get(filter_opts, :cursor)
        exclude_pipelines = Keyword.get(filter_opts, :exclude_pipelines, MapSet.new())
        exclude_entries = Keyword.get(filter_opts, :exclude_catalog_entries, MapSet.new())

        VantageJob
        |> Ash.Query.filter(state == :pending and job_kind == ^job_kind)
        |> apply_exclude_pipelines(exclude_pipelines)
        |> apply_exclude_entries(exclude_entries)
        |> apply_pending_cursor(cursor)
        |> Ash.Query.sort(inserted_at: :asc, id: :asc)
        |> Ash.Query.limit(page_limit)
        |> Ash.read(actor: @system_actor)
    end
  end

  defp load_expired_dispatched_jobs_page(now, page_limit, filter_opts, opts) do
    loaders = Keyword.get(opts, :loaders, %{})

    case Map.get(loaders, :expired_jobs_loader) do
      fun when is_function(fun, 3) ->
        fun.(now, page_limit, filter_opts)

      _ ->
        job_kind = Keyword.fetch!(filter_opts, :job_kind)
        cursor = Keyword.get(filter_opts, :cursor)
        exclude_pipelines = Keyword.get(filter_opts, :exclude_pipelines, MapSet.new())
        exclude_entries = Keyword.get(filter_opts, :exclude_catalog_entries, MapSet.new())

        VantageJob
        |> Ash.Query.filter(
          state == :dispatched and job_kind == ^job_kind and not is_nil(deadline_at) and
            deadline_at <= ^now
        )
        |> apply_exclude_pipelines(exclude_pipelines)
        |> apply_exclude_entries(exclude_entries)
        |> apply_expired_cursor(cursor)
        |> Ash.Query.sort(deadline_at: :asc, id: :asc)
        |> Ash.Query.limit(page_limit)
        |> Ash.read(actor: @system_actor)
    end
  end

  defp apply_exclude_pipelines(query, exclude_pipelines) do
    Enum.reduce(exclude_pipelines, query, fn
      {pid, pver}, q when is_binary(pid) and is_binary(pver) ->
        Ash.Query.filter(q, not (pipeline_id == ^pid and pipeline_version == ^pver))

      _, q ->
        q
    end)
  end

  defp apply_exclude_entries(query, exclude_entries) do
    entry_ids = Enum.reject(exclude_entries, &is_nil/1)

    if entry_ids == [] do
      query
    else
      Ash.Query.filter(query, catalog_entry_id not in ^entry_ids)
    end
  end

  defp apply_pending_cursor(query, {last_inserted_at, last_id})
       when not is_nil(last_inserted_at) and not is_nil(last_id) do
    Ash.Query.filter(
      query,
      inserted_at > ^last_inserted_at or (inserted_at == ^last_inserted_at and id > ^last_id)
    )
  end

  defp apply_pending_cursor(query, _), do: query

  defp apply_expired_cursor(query, {last_deadline_at, last_id})
       when not is_nil(last_deadline_at) and not is_nil(last_id) do
    Ash.Query.filter(
      query,
      deadline_at > ^last_deadline_at or (deadline_at == ^last_deadline_at and id > ^last_id)
    )
  end

  defp apply_expired_cursor(query, _), do: query

  defp pipeline_key(job) do
    {to_string(fetch_val(job, :pipeline_id) || ""),
     to_string(fetch_val(job, :pipeline_version) || "")}
  end

  defp unavailable_entry?(job, unavailable_entries) do
    case fetch_val(job, :catalog_entry_id) do
      nil -> false
      entry_id -> MapSet.member?(unavailable_entries, entry_id)
    end
  end

  defp kind_priority(job) do
    case normalize_job_kind(fetch_val(job, :job_kind)) do
      :live -> 0
      :backfill -> 1
    end
  end

  defp datetime_sort_key(%DateTime{} = dt), do: DateTime.to_unix(dt, :microsecond)
  defp datetime_sort_key(_), do: 0

  defp check_catalog_availability(job, opts) do
    loaders = Keyword.get(opts, :loaders, %{})
    entry_id = fetch_val(job, :catalog_entry_id)

    raw_entry =
      cond do
        is_nil(entry_id) ->
          {:ok, nil}

        is_function(Map.get(loaders, :catalog_entry_loader), 1) ->
          loaders.catalog_entry_loader.(entry_id)

        Keyword.has_key?(opts, :catalog_entry) ->
          {:ok, Keyword.get(opts, :catalog_entry)}

        map_size(loaders) > 0 ->
          {:ok, :skip_catalog_check}

        true ->
          Ash.get(RecordingCatalogEntry, entry_id, actor: @system_actor, not_found_error?: false)
      end

    case raw_entry do
      {:ok, :skip_catalog_check} ->
        {:ok, :playable, nil}

      {:ok, nil} when not is_nil(entry_id) ->
        {:ok, :recording_gone, nil}

      {:ok, entry} when is_map(entry) ->
        availability =
          if is_struct(entry, RecordingCatalogEntry) do
            RecordingCatalogEntry.availability(entry)
          else
            infer_map_entry_availability(entry)
          end

        {:ok, availability, entry}

      {:ok, nil} ->
        {:ok, :playable, nil}

      {:error, _} = err ->
        err
    end
  end

  defp infer_map_entry_availability(entry) do
    local = fetch_val(entry, :local_state)
    archive = fetch_val(entry, :archive_state)

    cond do
      local in [:present, "present"] or archive in [:verified, "verified"] ->
        :playable

      local in [:deleted, "deleted", :reclaimed, "reclaimed", :quarantined, "quarantined"] and
          archive in [
            :not_required,
            "not_required",
            :missing,
            "missing",
            :deleted,
            "deleted",
            nil
          ] ->
        :recording_gone

      true ->
        :recording_unavailable
    end
  end

  defp resolve_pipeline(job, opts) do
    loaders = Keyword.get(opts, :loaders, %{})

    cond do
      Keyword.has_key?(opts, :pipeline) ->
        Keyword.get(opts, :pipeline)

      # ---------------------------------------------------------------------------
      # Small normalizers & summary bookkeeping
      # ---------------------------------------------------------------------------

      is_function(Map.get(loaders, :pipeline_loader), 1) ->
        case loaders.pipeline_loader.(job) do
          {:ok, p} -> p
          %{} = p -> p
          _ -> nil
        end

      is_map(fetch_val(job, :vantage_pipeline)) and
          not match?(%Ash.NotLoaded{}, fetch_val(job, :vantage_pipeline)) ->
        fetch_val(job, :vantage_pipeline)

      map_size(loaders) > 0 ->
        nil

      true ->
        case VantagePipeline.get_by_pipeline_version(
               to_string(fetch_val(job, :pipeline_id)),
               to_string(fetch_val(job, :pipeline_version)),
               actor: @system_actor,
               not_found_error?: false
             ) do
          {:ok, %VantagePipeline{} = pipeline} -> pipeline
          _ -> nil
        end
    end
  end

  defp synthetic_pipeline_from_job(job) do
    payload = ensure_map(fetch_val(job, :job_payload))
    target_runner = fetch_val(job, :target_runner) || "camera_vlm"

    runner =
      if target_runner in ["camera_vlm", :camera_vlm], do: :camera_vlm, else: :external_worker

    capability =
      fetch_val(payload, :capability) ||
        if(runner == :external_worker, do: target_runner, else: "vantage.vlm.v1")

    %{
      pipeline_id: fetch_val(job, :pipeline_id),
      version: fetch_val(job, :pipeline_version),
      runner: runner,
      capability: capability,
      fallback_runner: fetch_val(payload, :fallback_runner),
      source_mode: fetch_val(payload, :source_mode) || :recorded_block,
      input_mode: fetch_val(payload, :input_mode) || :detection_crop,
      roi_polygons: fetch_val(payload, :roi_polygons) || [],
      crop_policy: fetch_val(payload, :crop_policy) || @default_crop_policy,
      signal_schema_id: fetch_val(payload, :signal_schema_id) || "vlm_narrative_event",
      signal_schema_version: fetch_val(payload, :signal_schema_version) || "1.0.0",
      display_contract_id: fetch_val(payload, :display_contract_id) || "vlm_narrative_event",
      vlm_config: fetch_val(payload, :vlm_config) || %{}
    }
  end

  defp external_worker_eligible?(capability, source_mode, now, opts) do
    case Keyword.get(opts, :worker_active_fn) do
      fun when is_function(fun, 2) ->
        fun.(capability, now) == true

      _ ->
        case eligible_workers(capability, source_mode, now, opts) do
          {:ok, [_ | _]} -> true
          _ -> false
        end
    end
  end

  defp worker_eligible?(worker, capability, source_mode_str, now) when is_map(worker) do
    expires_at = fetch_val(worker, :expires_at)
    health = fetch_val(worker, :health)
    capabilities = Enum.map(List.wrap(fetch_val(worker, :capabilities)), &to_string/1)
    source_modes = Enum.map(List.wrap(fetch_val(worker, :supported_source_modes)), &to_string/1)
    active_jobs = fetch_val(worker, :active_jobs)
    max_concurrency = fetch_val(worker, :max_concurrency)

    match?(%DateTime{}, expires_at) and
      DateTime.after?(expires_at, now) and
      health in [:ready, "ready"] and
      capability in capabilities and
      source_mode_str in source_modes and
      is_integer(active_jobs) and is_integer(max_concurrency) and
      active_jobs >= 0 and active_jobs < max_concurrency
  end

  defp worker_eligible?(_, _, _, _), do: false

  defp enabled?(opts) do
    case Keyword.fetch(opts, :enabled?) do
      {:ok, val} -> val == true
      :error -> deployment_enabled?(Keyword.get(opts, :env_fetch, &System.get_env/2))
    end
  end

  defp empty_summary do
    %{
      examined_count: 0,
      dispatched_count: 0,
      held_count: 0,
      cancelled_count: 0,
      failed_terminal_count: 0,
      superseded_count: 0,
      skipped_count: 0,
      publish_error: nil
    }
  end

  defp merge_summaries(a, b) do
    %{
      examined_count: a.examined_count + b.examined_count,
      dispatched_count: a.dispatched_count + b.dispatched_count,
      held_count: a.held_count + b.held_count,
      cancelled_count: a.cancelled_count + b.cancelled_count,
      failed_terminal_count: a.failed_terminal_count + b.failed_terminal_count,
      superseded_count: a.superseded_count + b.superseded_count,
      skipped_count: a.skipped_count + b.skipped_count,
      publish_error: a.publish_error || b.publish_error
    }
  end

  defp bump_summary(acc, :dispatched),
    do: %{
      acc
      | examined_count: acc.examined_count + 1,
        dispatched_count: acc.dispatched_count + 1
    }

  defp bump_summary(acc, :held),
    do: %{acc | examined_count: acc.examined_count + 1, held_count: acc.held_count + 1}

  defp bump_summary(acc, :cancelled),
    do: %{acc | examined_count: acc.examined_count + 1, cancelled_count: acc.cancelled_count + 1}

  defp bump_summary(acc, :failed_terminal),
    do: %{
      acc
      | examined_count: acc.examined_count + 1,
        failed_terminal_count: acc.failed_terminal_count + 1
    }

  defp bump_summary(acc, :superseded),
    do: %{
      acc
      | examined_count: acc.examined_count + 1,
        superseded_count: acc.superseded_count + 1
    }

  defp bump_summary(acc, :skipped),
    do: %{acc | examined_count: acc.examined_count + 1, skipped_count: acc.skipped_count + 1}

  defp record_error_outcome(acc, {:publish_failed, reason}) do
    %{acc | examined_count: acc.examined_count + 1, publish_error: acc.publish_error || reason}
  end

  defp record_error_outcome(acc, reason) do
    %{acc | examined_count: acc.examined_count + 1, publish_error: acc.publish_error || reason}
  end

  defp maybe_put_time_basis(opts, nil), do: opts

  defp maybe_put_time_basis(opts, entry) do
    case fetch_val(entry, :time_basis) do
      nil -> opts
      basis -> Keyword.put_new(opts, :time_basis, to_string(basis))
    end
  end

  defp normalize_time_basis(val, fallback) do
    case to_string(val || fallback || "received") do
      "camera_reported" -> "camera_reported"
      _ -> "received"
    end
  end

  defp normalize_runner(r) when r in [:camera_vlm, "camera_vlm", nil], do: :camera_vlm
  defp normalize_runner(r) when r in [:external_worker, "external_worker"], do: :external_worker
  defp normalize_runner(_), do: :camera_vlm

  defp normalize_optional_runner(r) when r in ["camera_vlm", :camera_vlm], do: "camera_vlm"
  defp normalize_optional_runner(_), do: nil

  defp normalize_source_mode(m) when m in [:live_keyframe_tap, "live_keyframe_tap"],
    do: :live_keyframe_tap

  defp normalize_source_mode(_), do: :recorded_block

  defp normalize_job_kind(k) when k in [:backfill, "backfill"], do: :backfill
  defp normalize_job_kind(_), do: :live

  defp normalize_state_atom(s) when is_atom(s), do: s
  defp normalize_state_atom("pending"), do: :pending
  defp normalize_state_atom("dispatched"), do: :dispatched
  defp normalize_state_atom("completed"), do: :completed
  defp normalize_state_atom("cancelled"), do: :cancelled
  defp normalize_state_atom("failed_terminal"), do: :failed_terminal
  defp normalize_state_atom(_), do: :pending

  defp normalize_capability(cap, runner) when is_binary(cap) do
    trimmed = String.trim(cap)
    if trimmed == "", do: default_capability(runner), else: trimmed
  end

  defp normalize_capability(_, runner), do: default_capability(runner)
  defp default_capability(:camera_vlm), do: "vantage.vlm.v1"
  defp default_capability(:external_worker), do: "vantage.custom.v1"

  defp normalize_error_class(reason) when is_binary(reason) do
    sanitized =
      reason
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9_:-]+/, "_")
      |> String.slice(0, 64)

    if Regex.match?(@error_class_regex, sanitized), do: sanitized, else: "dispatch_error"
  end

  defp normalize_error_class(reason), do: normalize_error_class(to_string(reason))

  defp maybe_string_id(nil), do: nil
  defp maybe_string_id(val), do: to_string(val)

  defp maybe_string(nil), do: nil
  defp maybe_string(val) when is_binary(val), do: val
  defp maybe_string(val), do: to_string(val)

  defp ensure_map(val) when is_map(val), do: val
  defp ensure_map(_), do: %{}

  defp non_empty_str(val, fallback) when is_binary(val) do
    trimmed = String.trim(val)
    if trimmed == "", do: fallback, else: trimmed
  end

  defp non_empty_str(val, _fallback) when is_atom(val) and not is_nil(val),
    do: Atom.to_string(val)

  defp non_empty_str(_, fallback), do: fallback

  defp positive_int(val, _fallback) when is_integer(val) and val >= 1, do: val
  defp positive_int(_, fallback), do: fallback

  defp non_neg_int(val, _fallback) when is_integer(val) and val >= 0, do: val
  defp non_neg_int(_, fallback), do: fallback

  defp clamp_int(val, min_v, max_v) when is_integer(val), do: val |> max(min_v) |> min(max_v)

  defp clamp_int(_, min_v, _max_v), do: min_v

  defp non_neg_float(val, _fallback) when is_number(val) and val >= 0, do: val * 1.0
  defp non_neg_float(_, fallback), do: fallback * 1.0

  defp unit_float(val, fallback), do: clamp_float(val, 0.0, 1.0, fallback)

  defp clamp_float(val, min_v, max_v, _fallback) when is_number(val) do
    val |> Kernel.*(1.0) |> max(min_v) |> min(max_v)
  end

  defp clamp_float(_, _min_v, _max_v, fallback), do: fallback * 1.0

  defp clamp_unit(val) when is_number(val), do: val |> Kernel.*(1.0) |> max(0.0) |> min(1.0)

  defp fetch_val(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, val} -> val
      :error -> Map.get(map, Atom.to_string(key))
    end
  end
end
