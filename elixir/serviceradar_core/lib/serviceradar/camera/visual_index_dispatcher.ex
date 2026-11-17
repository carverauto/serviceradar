defmodule ServiceRadar.Camera.VisualIndexDispatcher do
  @moduledoc """
  Transactional outbox admission, metadata-only NATS JetStream publisher, and
  `MaxDeliver` exhaustion reconciler for recorded-block visual keyframe indexing
  (`1.4`, `design.md` `2.1`–`2.2`).

  - `maybe_admit_for_catalog_entry/3`: samples IDR keyframe fragments from the
    frozen block descriptor and inserts an idempotent `:pending` `VisualIndexJob`
    when the camera/profile's `CameraRecordingPolicy` has
    `visual_index_mode == :keyframes` and the catalog entry is non-quarantined.
  - `dispatch_pending_jobs/1` / `dispatch_job/2`: publishes bounded metadata-only
    JSON envelopes (`<= 4 KiB`, zero media bytes, zero storage credentials) onto
    `media.jobs.visual_index.v1` (`:live`) or `media.jobs.visual_index.backfill.v1`
    (`:backfill`).
  - `reconcile_exhausted_job/3` / `reconcile_expired_dispatched_jobs/1`:
    transitions exhausted jobs to `:failed_terminal` and records deduplicated
    `TripwireHealth` check `"camera.visual_index.failed_terminal"`.
  """

  import Ash.Expr

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Camera.CameraRecordingPolicy
  alias ServiceRadar.Camera.RecordingCatalogEntry
  alias ServiceRadar.Camera.VisualIndexJob
  alias ServiceRadar.NATS.JetStreamPublish
  alias ServiceRadar.Observability.TripwireHealth
  alias ServiceRadar.Storage.StorageEntitlements

  require Ash.Query
  require Logger

  @live_subject "media.jobs.visual_index.v1"
  @backfill_subject "media.jobs.visual_index.backfill.v1"
  @tripwire_check "camera.visual_index.failed_terminal"
  @max_envelope_bytes 4_096
  @default_budget_ms 30_000
  @default_deadline_seconds 60
  @default_batch_limit 50
  @max_batch_limit 250

  @default_detector_model_id "rtdetr-r18"
  @default_detector_model_version "2026.1"
  @default_embedder_model_id "siglip-b16-384"
  @default_embedder_model_version "2026.1"
  @default_embedding_dim 768

  @error_class_regex ~r/\A[a-z0-9_:-]{1,64}\z/

  @system_actor SystemActor.system(:camera_visual_index_dispatcher)

  @doc "NATS JetStream subject for live visual indexing jobs."
  @spec live_subject() :: String.t()
  def live_subject, do: @live_subject

  @doc "NATS JetStream subject for historical/model-upgrade backfill jobs."
  @spec backfill_subject() :: String.t()
  def backfill_subject, do: @backfill_subject

  @doc "Tripwire health check identifier for terminal visual index failures."
  @spec tripwire_check_id() :: String.t()
  def tripwire_check_id, do: @tripwire_check

  @doc """
  Resolves the active `(detector_model_id, detector_model_version, embedder_model_id, embedder_model_version, embedding_dim)`
  configuration from `opts` or `:serviceradar_core` `:camera_visual_indexing`.
  """
  @spec active_model_config(keyword()) :: %{
          detector_model_id: String.t(),
          detector_model_version: String.t(),
          embedder_model_id: String.t(),
          embedder_model_version: String.t(),
          model_id: String.t(),
          model_version: String.t(),
          embedding_dim: 512 | 768
        }
  def active_model_config(opts \\ []) when is_list(opts) do
    app_cfg = Application.get_env(:serviceradar_core, :camera_visual_indexing, [])
    merged = Keyword.merge(List.wrap(app_cfg), opts)

    detector_id =
      non_empty_str(Keyword.get(merged, :detector_model_id), @default_detector_model_id)

    detector_ver =
      non_empty_str(
        Keyword.get(merged, :detector_model_version),
        @default_detector_model_version
      )

    embedder_id =
      non_empty_str(
        Keyword.get(merged, :embedder_model_id) || Keyword.get(merged, :model_id),
        @default_embedder_model_id
      )

    embedder_ver =
      non_empty_str(
        Keyword.get(merged, :embedder_model_version) || Keyword.get(merged, :model_version),
        @default_embedder_model_version
      )

    dim =
      case Keyword.get(merged, :embedding_dim, @default_embedding_dim) do
        512 -> 512
        768 -> 768
        _ -> @default_embedding_dim
      end

    %{
      detector_model_id: detector_id,
      detector_model_version: detector_ver,
      embedder_model_id: embedder_id,
      embedder_model_version: embedder_ver,
      model_id: embedder_id,
      model_version: embedder_ver,
      embedding_dim: dim
    }
  end

  @doc """
  Deterministically samples keyframe-aligned CMAF fragments from a frozen
  `RecordingBlock` descriptor according to `min_interval_ms` (`500..60_000`) and
  `max_frames_per_block` (`1..512`).
  """
  @spec sample_descriptor_fragments(map(), pos_integer(), pos_integer()) :: [map()]
  def sample_descriptor_fragments(descriptor, min_interval_ms \\ 2000, max_frames \\ 64)
      when is_map(descriptor) do
    interval_ns = clamp_int(min_interval_ms, 500, 60_000) * 1_000_000
    cap = clamp_int(max_frames, 1, 512)
    raw_fragments = Map.get(descriptor, "fragments") || Map.get(descriptor, :fragments) || []

    sorted =
      raw_fragments
      |> Enum.filter(&keyframe_fragment?/1)
      |> Enum.sort_by(&(fetch_val(&1, :sequence) || 0))

    {kept_rev, _last_ns, _count} =
      Enum.reduce_while(sorted, {[], nil, 0}, fn frag, {acc, last_ns, count} ->
        if count >= cap do
          {:halt, {acc, last_ns, count}}
        else
          start_ns = fragment_start_ns(frag)

          if is_nil(last_ns) or start_ns - last_ns >= interval_ns do
            normalized = normalize_sampled_fragment(frag)
            {:cont, {[normalized | acc], start_ns, count + 1}}
          else
            {:cont, {acc, last_ns, count}}
          end
        end
      end)

    Enum.reverse(kept_rev)
  end

  @doc """
  Transactionally admits a `:pending` `VisualIndexJob` for a sealed,
  non-quarantined `RecordingCatalogEntry` when its `CameraRecordingPolicy` has
  `visual_index_mode == :keyframes`.

  Returns `{:ok, nil}` when visual indexing is disabled, the entry is quarantined
  or unplayable, or hosted recording jobs are suspended.
  """
  @spec maybe_admit_for_catalog_entry(map(), map(), keyword()) ::
          {:ok, VisualIndexJob.t() | nil} | {:error, term()}
  def maybe_admit_for_catalog_entry(entry, descriptor, opts \\ [])
      when is_map(entry) and is_map(descriptor) and is_list(opts) do
    cond do
      not RecordingCatalogEntry.playable?(entry) ->
        {:ok, nil}

      indexing_suspended?(opts) ->
        {:ok, nil}

      true ->
        case resolve_policy_for_entry(entry, opts) do
          {:ok, %{visual_index_mode: :keyframes} = policy} ->
            enqueue_for_policy(entry, descriptor, policy, opts)

          {:ok, _off_or_nil} ->
            {:ok, nil}

          {:error, _} = err ->
            err
        end
    end
  end

  @doc """
  Builds the metadata-only JetStream envelope (`<= 4 KiB`, zero media bytes,
  zero credentials) for a `VisualIndexJob`.
  """
  @spec build_envelope(map(), keyword()) :: {:ok, String.t(), binary(), map()} | {:error, term()}
  def build_envelope(job, opts \\ []) when is_map(job) and is_list(opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    budget_ms = clamp_int(Keyword.get(opts, :budget_ms, @default_budget_ms), 1_000, 300_000)

    deadline_at =
      case fetch_val(job, :deadline_at) do
        %DateTime{} = dt -> dt
        _ -> DateTime.shift(now, second: @default_deadline_seconds)
      end

    job_kind = normalize_job_kind(fetch_val(job, :job_kind))
    subject = if job_kind == :backfill, do: @backfill_subject, else: @live_subject

    sampled_seqs =
      job
      |> fetch_val(:sampled_fragments)
      |> List.wrap()
      |> Enum.map(&fetch_val(&1, :sequence))
      |> Enum.filter(&is_integer/1)

    attempt = (fetch_val(job, :attempt_count) || 0) + 1

    payload = %{
      "schema_version" => 1,
      "job_id" => to_string(fetch_val(job, :id)),
      "job_kind" => Atom.to_string(job_kind),
      "catalog_entry_id" => to_string(fetch_val(job, :catalog_entry_id)),
      "camera_source_id" => to_string(fetch_val(job, :camera_source_id)),
      "stream_profile_id" => to_string(fetch_val(job, :stream_profile_id)),
      "descriptor_sha256" => fetch_val(job, :descriptor_sha256),
      "detector_model_id" => fetch_val(job, :detector_model_id),
      "detector_model_version" => fetch_val(job, :detector_model_version),
      "embedder_model_id" => fetch_val(job, :embedder_model_id),
      "embedder_model_version" => fetch_val(job, :embedder_model_version),
      "model_id" => fetch_val(job, :embedder_model_id),
      "model_version" => fetch_val(job, :embedder_model_version),
      "embedding_dim" => fetch_val(job, :embedding_dim),
      "fragment_count" => length(sampled_seqs),
      "sampled_fragment_sequences" => sampled_seqs,
      "attempt" => attempt,
      "max_attempts" => fetch_val(job, :max_attempts) || 5,
      "budget_ms" => budget_ms,
      "deadline_at" => DateTime.to_iso8601(deadline_at),
      "deadline_unix_ms" => DateTime.to_unix(deadline_at, :millisecond)
    }

    encoded = Jason.encode!(payload)

    if byte_size(encoded) <= @max_envelope_bytes do
      {:ok, subject, encoded, payload}
    else
      compact = Map.delete(payload, "sampled_fragment_sequences")
      compact_encoded = Jason.encode!(compact)

      if byte_size(compact_encoded) <= @max_envelope_bytes do
        {:ok, subject, compact_encoded, compact}
      else
        {:error, :envelope_too_large}
      end
    end
  end

  @doc """
  Publishes a single `:pending` (or retry-eligible `:dispatched`) `VisualIndexJob`
  onto NATS JetStream via `opts[:publisher]` (default `&JetStreamPublish.publish/3`)
  and marks it `:dispatched`.

  Cancels the job without publishing if its `RecordingCatalogEntry` has become
  quarantined or terminally deleted.
  """
  @spec dispatch_job(VisualIndexJob.t() | String.t(), keyword()) ::
          {:ok, VisualIndexJob.t()} | {:error, term()}
  def dispatch_job(job_or_id, opts \\ []) when is_list(opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now())

    deadline_sec =
      clamp_int(Keyword.get(opts, :deadline_seconds, @default_deadline_seconds), 5, 600)

    deadline_at = DateTime.shift(now, second: deadline_sec)

    with {:ok, job} <- load_job(job_or_id, opts) do
      cond do
        job.state in [:completed, :cancelled, :failed_terminal] ->
          {:ok, job}

        job.attempt_count >= job.max_attempts ->
          reconcile_exhausted_job(job, "max_deliver_exhausted", opts)

        catalog_entry_gone_or_quarantined?(job.catalog_entry_id, opts) ->
          cancel_job(job, "source_deleted_or_quarantined")

        true ->
          publish_and_mark_dispatched(job, now, deadline_at, opts)
      end
    end
  end

  @doc """
  Publishes up to `opts[:limit]` (default `50`) `:pending` `VisualIndexJob` rows,
  prioritizing `:live` jobs ahead of `:backfill` jobs.
  """
  @spec dispatch_pending_jobs(keyword()) ::
          {:ok,
           %{
             dispatched_count: non_neg_integer(),
             cancelled_count: non_neg_integer(),
             failed_count: non_neg_integer()
           }}
  def dispatch_pending_jobs(opts \\ []) when is_list(opts) do
    limit = clamp_int(Keyword.get(opts, :limit, @default_batch_limit), 1, @max_batch_limit)

    pending_jobs =
      VisualIndexJob
      |> Ash.Query.filter(state == :pending)
      |> Ash.Query.limit(limit * 2)
      |> Ash.read!(actor: @system_actor)
      |> Enum.sort_by(fn j ->
        kind_rank = if j.job_kind == :live, do: 0, else: 1

        ts =
          if match?(%DateTime{}, j.inserted_at),
            do: DateTime.to_unix(j.inserted_at, :microsecond),
            else: 0

        {kind_rank, ts, to_string(j.id)}
      end)
      |> Enum.take(limit)

    summary =
      Enum.reduce(
        pending_jobs,
        %{dispatched_count: 0, cancelled_count: 0, failed_count: 0},
        fn job, acc ->
          case dispatch_job(job, opts) do
            {:ok, %{state: :dispatched}} ->
              %{acc | dispatched_count: acc.dispatched_count + 1}

            {:ok, %{state: :cancelled}} ->
              %{acc | cancelled_count: acc.cancelled_count + 1}

            _ ->
              %{acc | failed_count: acc.failed_count + 1}
          end
        end
      )

    {:ok, summary}
  end

  @doc """
  Marks an exhausted `VisualIndexJob` `:failed_terminal` (`MaxDeliver` advisory or
  attempt budget exhaustion) and records `TripwireHealth` check
  `"camera.visual_index.failed_terminal"`.
  """
  @spec reconcile_exhausted_job(VisualIndexJob.t() | String.t(), String.t(), keyword()) ::
          {:ok, VisualIndexJob.t()} | {:error, term()}
  def reconcile_exhausted_job(job_or_id, error_class \\ "max_deliver_exhausted", opts \\ [])
      when is_binary(error_class) and is_list(opts) do
    normalized_err = sanitize_error_class(error_class)

    with {:ok, job} <- load_job(job_or_id, opts) do
      cond do
        job.state in [:completed, :cancelled] ->
          {:ok, job}

        job.state == :failed_terminal ->
          record_tripwire_failure(job, normalized_err, opts)
          {:ok, job}

        true ->
          with {:ok, updated} <-
                 job
                 |> Ash.Changeset.for_update(:mark_failed_terminal, %{
                   last_error_class: normalized_err
                 })
                 |> Ash.Changeset.filter(expr(state in [:pending, :dispatched]))
                 |> Ash.update(actor: @system_actor) do
            record_tripwire_failure(updated, normalized_err, opts)
            {:ok, updated}
          end
      end
    end
  end

  @doc """
  Reconciles `:dispatched` jobs whose `deadline_at` has passed: jobs that have
  reached `max_attempts` transition to `:failed_terminal` (with `TripwireHealth`),
  while jobs with remaining attempts are re-dispatched or cancelled if deleted.
  """
  @spec reconcile_expired_dispatched_jobs(keyword()) ::
          {:ok,
           %{
             failed_terminal_count: non_neg_integer(),
             retried_count: non_neg_integer(),
             cancelled_count: non_neg_integer()
           }}
  def reconcile_expired_dispatched_jobs(opts \\ []) when is_list(opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    limit = clamp_int(Keyword.get(opts, :limit, @default_batch_limit), 1, @max_batch_limit)

    expired =
      VisualIndexJob
      |> Ash.Query.filter(
        state == :dispatched and not is_nil(deadline_at) and deadline_at <= ^now
      )
      |> Ash.Query.sort(deadline_at: :asc, id: :asc)
      |> Ash.Query.limit(limit)
      |> Ash.read!(actor: @system_actor)

    summary =
      Enum.reduce(
        expired,
        %{failed_terminal_count: 0, retried_count: 0, cancelled_count: 0},
        fn job, acc ->
          reconcile_single_expired(job, acc, opts)
        end
      )

    {:ok, summary}
  end

  defp reconcile_single_expired(job, acc, opts) do
    if job.attempt_count >= job.max_attempts do
      case reconcile_exhausted_job(job, "max_deliver_exhausted", opts) do
        {:ok, _} -> %{acc | failed_terminal_count: acc.failed_terminal_count + 1}
        _ -> acc
      end
    else
      case dispatch_job(job, opts) do
        {:ok, %{state: :dispatched}} ->
          %{acc | retried_count: acc.retried_count + 1}

        {:ok, %{state: :cancelled}} ->
          %{acc | cancelled_count: acc.cancelled_count + 1}

        {:ok, %{state: :failed_terminal}} ->
          %{acc | failed_terminal_count: acc.failed_terminal_count + 1}

        _ ->
          acc
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Internal helpers
  # ---------------------------------------------------------------------------

  defp enqueue_for_policy(entry, descriptor, policy, opts) do
    min_interval_ms = fetch_val(policy, :visual_index_min_interval_ms) || 2000
    max_frames = fetch_val(policy, :visual_index_max_frames_per_block) || 64
    sampled = sample_descriptor_fragments(descriptor, min_interval_ms, max_frames)

    if sampled == [] do
      {:ok, nil}
    else
      model_cfg = active_model_config(opts)
      job_kind = normalize_job_kind(Keyword.get(opts, :job_kind, :live))
      max_attempts = clamp_int(Keyword.get(opts, :max_attempts, 5), 1, 20)

      attrs = %{
        catalog_entry_id: fetch_val(entry, :id),
        camera_source_id: fetch_val(entry, :camera_source_id),
        stream_profile_id: fetch_val(entry, :stream_profile_id),
        job_kind: job_kind,
        state: :pending,
        attempt_count: 0,
        max_attempts: max_attempts,
        detector_model_id: model_cfg.detector_model_id,
        detector_model_version: model_cfg.detector_model_version,
        embedder_model_id: model_cfg.embedder_model_id,
        embedder_model_version: model_cfg.embedder_model_version,
        embedding_dim: model_cfg.embedding_dim,
        sampled_fragments: sampled,
        descriptor_sha256: fetch_val(entry, :descriptor_sha256)
      }

      VisualIndexJob
      |> Ash.Changeset.for_create(:enqueue, attrs, actor: @system_actor)
      |> Ash.create(actor: @system_actor)
    end
  end

  defp resolve_policy_for_entry(entry, opts) do
    loaders = Keyword.get(opts, :loaders, %{})
    policy_id = fetch_val(entry, :policy_id)
    cam_id = fetch_val(entry, :camera_source_id)
    prof_id = fetch_val(entry, :stream_profile_id)

    cond do
      is_function(Map.get(loaders, :policy_loader), 1) ->
        loaders.policy_loader.(entry)

      is_function(Map.get(loaders, :policies_loader), 0) ->
        with {:ok, policies} <- loaders.policies_loader.() do
          {:ok, find_matching_policy(policies, policy_id, cam_id, prof_id)}
        end

      map_size(loaders) > 0 ->
        {:ok, nil}

      true ->
        lookup_policy_in_db(policy_id, cam_id, prof_id)
    end
  end

  defp find_matching_policy(policies, policy_id, cam_id, prof_id) do
    Enum.find(policies, fn pol ->
      (not is_nil(policy_id) and to_string(fetch_val(pol, :id)) == to_string(policy_id)) or
        (to_string(fetch_val(pol, :camera_source_id)) == to_string(cam_id) and
           to_string(fetch_val(pol, :stream_profile_id)) == to_string(prof_id))
    end)
  end

  defp lookup_policy_in_db(policy_id, cam_id, prof_id) do
    by_id_result =
      if is_binary(policy_id) do
        Ash.get(CameraRecordingPolicy, policy_id, actor: @system_actor, not_found_error?: false)
      else
        {:ok, nil}
      end

    case by_id_result do
      {:ok, %CameraRecordingPolicy{} = found} ->
        {:ok, found}

      _ when is_binary(cam_id) and is_binary(prof_id) ->
        CameraRecordingPolicy
        |> Ash.Query.for_read(
          :by_camera_profile,
          %{camera_source_id: cam_id, stream_profile_id: prof_id},
          actor: @system_actor
        )
        |> Ash.read_one(actor: @system_actor)

      _ ->
        {:ok, nil}
    end
  end

  defp indexing_suspended?(opts) do
    case StorageEntitlements.archive_uploads_held?(opts) do
      {true, _reason} -> true
      _ -> false
    end
  end

  defp publish_and_mark_dispatched(job, now, deadline_at, opts) do
    job_with_deadline = Map.put(job, :deadline_at, deadline_at)

    with {:ok, subject, encoded, _payload} <- build_envelope(job_with_deadline, opts),
         msg_id = build_msg_id(job),
         :ok <- invoke_publisher(subject, encoded, msg_id, opts) do
      job
      |> Ash.Changeset.for_update(:mark_dispatched, %{
        dispatched_at: now,
        deadline_at: deadline_at,
        last_error_class: nil
      })
      |> Ash.Changeset.filter(expr(state in [:pending, :dispatched]))
      |> Ash.update(actor: @system_actor)
    end
  end

  defp build_msg_id(job) do
    attempt = (fetch_val(job, :attempt_count) || 0) + 1
    id = fetch_val(job, :id)
    if attempt == 1, do: "visual-index:#{id}", else: "visual-index:#{id}:#{attempt}"
  end

  defp invoke_publisher(subject, encoded, msg_id, opts) do
    case Keyword.get(opts, :publisher) do
      pub when is_function(pub, 3) ->
        normalize_publish_result(pub.(subject, encoded, msg_id: msg_id))

      pub when is_function(pub, 2) ->
        normalize_publish_result(pub.(subject, encoded))

      nil ->
        JetStreamPublish.publish(subject, encoded, msg_id: msg_id)
    end
  end

  defp normalize_publish_result(:ok), do: :ok
  defp normalize_publish_result({:ok, _}), do: :ok
  defp normalize_publish_result({:error, _} = err), do: err
  defp normalize_publish_result(other), do: {:error, other}

  defp load_job(%VisualIndexJob{} = job, _opts), do: {:ok, job}

  defp load_job(job_id, opts) when is_binary(job_id) do
    loaders = Keyword.get(opts, :loaders, %{})

    with {:ok, uuid} <- cast_uuid(job_id) do
      case Map.get(loaders, :job_loader) do
        loader when is_function(loader, 1) ->
          case loader.(uuid) do
            {:ok, %{} = job} -> {:ok, job}
            {:ok, nil} -> {:error, :job_not_found}
            other -> other
          end

        _ ->
          case VisualIndexJob.get_by_id(uuid, actor: @system_actor, not_found_error?: false) do
            {:ok, %VisualIndexJob{} = job} -> {:ok, job}
            {:ok, nil} -> {:error, :job_not_found}
            {:error, _} = err -> err
          end
      end
    end
  end

  defp load_job(_, _opts), do: {:error, :invalid_job_id}

  defp catalog_entry_gone_or_quarantined?(catalog_entry_id, opts) do
    loaders = Keyword.get(opts, :loaders, %{})

    entry_res =
      case Map.get(loaders, :entry_loader) do
        loader when is_function(loader, 1) ->
          loader.(catalog_entry_id)

        _ when map_size(loaders) > 0 ->
          {:ok, :skip_check}

        _ ->
          Ash.get(RecordingCatalogEntry, catalog_entry_id,
            actor: @system_actor,
            not_found_error?: false
          )
      end

    case entry_res do
      {:ok, :skip_check} ->
        false

      {:ok, nil} ->
        true

      {:ok, entry} ->
        local_state = fetch_val(entry, :local_state)
        archive_state = fetch_val(entry, :archive_state)

        local_state == :quarantined or
          (local_state == :reclaimed and archive_state in [:deleted, :not_required])

      _ ->
        false
    end
  end

  defp cancel_job(job, reason_class) do
    job
    |> Ash.Changeset.for_update(:mark_cancelled, %{last_error_class: reason_class})
    |> Ash.Changeset.filter(expr(state in [:pending, :dispatched]))
    |> Ash.update(actor: @system_actor)
  end

  defp record_tripwire_failure(job, error_class, opts) do
    metadata = %{
      "job_id" => to_string(fetch_val(job, :id)),
      "catalog_entry_id" => to_string(fetch_val(job, :catalog_entry_id)),
      "camera_source_id" => to_string(fetch_val(job, :camera_source_id)),
      "stream_profile_id" => to_string(fetch_val(job, :stream_profile_id)),
      "embedder_model_id" => fetch_val(job, :embedder_model_id),
      "embedder_model_version" => fetch_val(job, :embedder_model_version),
      "last_error_class" => error_class,
      "attempt_count" => fetch_val(job, :attempt_count)
    }

    case Keyword.get(opts, :tripwire_recorder) do
      recorder when is_function(recorder, 4) ->
        recorder.(@tripwire_check, false, metadata, refresh_metadata: true)

      recorder when is_function(recorder, 3) ->
        recorder.(@tripwire_check, false, metadata)

      nil ->
        TripwireHealth.record(@tripwire_check, false, metadata, refresh_metadata: true)
    end
  end

  defp keyframe_fragment?(frag) when is_map(frag) do
    keyframe_flag =
      case Map.fetch(frag, "keyframe") do
        {:ok, val} -> val
        :error -> Map.get(frag, :keyframe, true)
      end

    keyframe_flag != false and is_integer(fetch_val(frag, :sequence)) and
      is_integer(fetch_val(frag, :offset)) and is_integer(fetch_val(frag, :length)) and
      is_binary(fetch_val(frag, :sha256))
  end

  defp keyframe_fragment?(_), do: false

  defp fragment_start_ns(frag) do
    fetch_val(frag, :start_ns) ||
      fetch_val(frag, :pts_ns) ||
      fetch_val(frag, :media_offset_ns) ||
      0
  end

  defp normalize_sampled_fragment(frag) do
    %{
      "sequence" => fetch_val(frag, :sequence),
      "offset" => fetch_val(frag, :offset),
      "length" => fetch_val(frag, :length),
      "start_ns" => fragment_start_ns(frag),
      "duration_ns" => fetch_val(frag, :duration_ns) || 0,
      "sha256" => fetch_val(frag, :sha256)
    }
  end

  defp sanitize_error_class(raw) when is_binary(raw) do
    cleaned = raw |> String.trim() |> String.downcase() |> String.slice(0, 64)
    if Regex.match?(@error_class_regex, cleaned), do: cleaned, else: "worker_exhausted"
  end

  defp normalize_job_kind(val) when val in [:backfill, "backfill"], do: :backfill
  defp normalize_job_kind(_), do: :live

  defp non_empty_str(val, fallback) when is_binary(val) do
    trimmed = String.trim(val)
    if trimmed == "", do: fallback, else: trimmed
  end

  defp non_empty_str(_, fallback), do: fallback

  defp clamp_int(val, min_v, max_v) when is_integer(val), do: val |> max(min_v) |> min(max_v)
  defp clamp_int(_, min_v, _max_v), do: min_v

  defp cast_uuid(val) when is_binary(val) do
    case Ecto.UUID.cast(val) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :invalid_job_id}
    end
  end

  defp fetch_val(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, val} -> val
      :error -> Map.get(map, Atom.to_string(key))
    end
  end
end
