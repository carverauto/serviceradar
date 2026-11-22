defmodule ServiceRadar.Camera.VisualIndexBackfill do
  @moduledoc """
  Bounded model-upgrade backfill scheduler and superseded-embedding batch cleanup
  for recorded-camera semantic clip search (`Stage 3.4`, `design.md` `4.3`).

  Invariants:
  - Backfill scans strictly playable, non-quarantined `RecordingCatalogEntry`
    rows (`recording_block_id IS NOT NULL`, `local_state != :quarantined`,
    `quarantine_reason IS NULL`, and `local_state == :present or archive_state == :verified`),
    never reviving or re-indexing `:reclaimed`, `:deleted`, `:missing`-only, or
    `:quarantined` blocks while preserving `RecordingHold`-pinned playable blocks.
  - Backfill jobs use `job_kind: :backfill` (`media.jobs.visual_index.backfill.v1`)
    so live block indexing retains priority.
  - Superseded `(model_id, model_version)` vector projections are purged in bounded
    `ctid` batches (`<= 5,000` rows per statement) once the active search model advances.
  """

  alias Ash.Error.Forbidden
  alias Ecto.Adapters.SQL
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Camera.CameraRecordingPolicy
  alias ServiceRadar.Camera.RecordingBlock
  alias ServiceRadar.Camera.RecordingCatalogEntry
  alias ServiceRadar.Camera.VisualIndexDispatcher
  alias ServiceRadar.Camera.VisualIndexJob
  alias ServiceRadar.Identity.RBAC
  alias ServiceRadar.Repo

  require Ash.Query

  @system_actor SystemActor.system(:camera_visual_index_backfill)
  @operate_permissions ["settings.recording.manage", "settings.recording.operate"]

  @default_batch_limit 100
  @max_batch_limit 500
  @default_cleanup_batch_size 1_000
  @max_cleanup_batch_size 5_000

  @doc """
  Enqueues bounded `:backfill` `VisualIndexJob` rows for playable, non-quarantined
  `RecordingCatalogEntry` blocks targeting the configured or specified model (`3.4`).
  """
  @spec enqueue_model_backfill(map() | keyword(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def enqueue_model_backfill(params \\ %{}, opts \\ [])
      when (is_map(params) or is_list(params)) and is_list(opts) do
    attrs = to_map(params)

    with :ok <- authorize_optional_operator(opts),
         {:ok, filter_spec} <- validate_backfill_params(attrs, opts) do
      entries = query_playable_catalog_batch(filter_spec)
      blocks_by_id = load_recording_blocks_map(entries)
      policies_by_pair = load_policies_map(entries)
      existing_jobs = load_existing_jobs_map(entries, filter_spec.model_cfg)

      summary =
        Enum.reduce_while(
          entries,
          %{
            scanned_count: 0,
            enqueued_count: 0,
            skipped_existing_count: 0,
            job_ids: [],
            next_cursor_id: nil
          },
          fn entry, acc ->
            process_backfill_entry(
              entry,
              blocks_by_id,
              policies_by_pair,
              existing_jobs,
              filter_spec,
              opts,
              acc
            )
          end
        )

      backfill_summary(summary, entries, filter_spec.limit)
    end
  end

  defp backfill_summary({:error, _} = error, _entries, _limit), do: error

  defp backfill_summary(summary, entries, limit) do
    next_cursor = if length(entries) == limit, do: to_string(List.last(entries).id)

    {:ok, %{summary | job_ids: Enum.reverse(summary.job_ids), next_cursor_id: next_cursor}}
  end

  @doc """
  Deletes superseded `(model_id, model_version)` rows from
  `platform.camera_visual_embeddings` in a bounded `ctid` batch (`<= 5,000` rows)
  and prunes any resulting orphan `platform.camera_visual_frames` rows (`3.4`).
  """
  @spec cleanup_superseded_embeddings(map() | keyword(), keyword()) ::
          {:ok,
           %{
             deleted_embeddings_count: non_neg_integer(),
             deleted_frames_count: non_neg_integer()
           }}
          | {:error, term()}
  def cleanup_superseded_embeddings(params \\ %{}, opts \\ [])
      when (is_map(params) or is_list(params)) and is_list(opts) do
    attrs = to_map(params)

    with :ok <- authorize_optional_operator(opts),
         {:ok, keep_model_id, keep_model_version, batch_size, prune_frames?} <-
           validate_cleanup_params(attrs, opts) do
      delete_emb_sql = """
      DELETE FROM platform.camera_visual_embeddings
      WHERE ctid IN (
        SELECT ctid
        FROM platform.camera_visual_embeddings
        WHERE model_id <> $1 OR model_version <> $2
        LIMIT $3
      )
      """

      with {:ok, %{num_rows: deleted_embs}} <-
             SQL.query(Repo, delete_emb_sql, [keep_model_id, keep_model_version, batch_size]),
           {:ok, deleted_frames} <- maybe_prune_orphan_frames(prune_frames?, batch_size) do
        {:ok,
         %{
           deleted_embeddings_count: deleted_embs,
           deleted_frames_count: deleted_frames
         }}
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Backfill internals
  # ---------------------------------------------------------------------------

  defp process_backfill_entry(
         %RecordingCatalogEntry{} = entry,
         blocks_by_id,
         policies_by_pair,
         existing_jobs,
         filter_spec,
         opts,
         acc
       ) do
    acc = %{acc | scanned_count: acc.scanned_count + 1}
    existing = Map.get(existing_jobs, to_string(entry.id))

    cond do
      not RecordingCatalogEntry.playable?(entry) ->
        {:cont, acc}

      not filter_spec.force? and not is_nil(existing) and
          existing.state in [:pending, :dispatched, :completed] ->
        {:cont, %{acc | skipped_existing_count: acc.skipped_existing_count + 1}}

      true ->
        enqueue_entry_backfill_job(entry, blocks_by_id, policies_by_pair, filter_spec, opts, acc)
    end
  end

  defp enqueue_entry_backfill_job(entry, blocks_by_id, policies_by_pair, filter_spec, opts, acc) do
    block = Map.get(blocks_by_id, to_string(entry.recording_block_id))

    descriptor =
      case block do
        %RecordingBlock{descriptor: desc} when is_map(desc) -> desc
        _ -> nil
      end

    policy =
      Map.get(
        policies_by_pair,
        {to_string(entry.camera_source_id), to_string(entry.stream_profile_id)}
      )

    min_interval_ms =
      filter_spec.min_interval_ms ||
        (policy && policy.visual_index_min_interval_ms) ||
        2000

    max_frames =
      filter_spec.max_frames_per_block ||
        (policy && policy.visual_index_max_frames_per_block) ||
        64

    sampled =
      if is_map(descriptor) do
        VisualIndexDispatcher.sample_descriptor_fragments(descriptor, min_interval_ms, max_frames)
      else
        []
      end

    if sampled == [] do
      {:cont, acc}
    else
      persist_and_maybe_dispatch_backfill(entry, sampled, filter_spec, opts, acc)
    end
  end

  defp persist_and_maybe_dispatch_backfill(entry, sampled, filter_spec, opts, acc) do
    mc = filter_spec.model_cfg

    job_attrs = %{
      catalog_entry_id: entry.id,
      camera_source_id: entry.camera_source_id,
      stream_profile_id: entry.stream_profile_id,
      job_kind: :backfill,
      state: :pending,
      attempt_count: 0,
      max_attempts: 5,
      detector_model_id: mc.detector_model_id,
      detector_model_version: mc.detector_model_version,
      embedder_model_id: mc.embedder_model_id,
      embedder_model_version: mc.embedder_model_version,
      embedding_dim: mc.embedding_dim,
      sampled_fragments: sampled,
      descriptor_sha256: entry.descriptor_sha256
    }

    case VisualIndexJob
         |> Ash.Changeset.for_create(:enqueue, job_attrs)
         |> Ash.create(actor: @system_actor) do
      {:ok, %VisualIndexJob{} = job} ->
        enqueued = %{
          acc
          | enqueued_count: acc.enqueued_count + 1,
            job_ids: [to_string(job.id) | acc.job_ids]
        }

        maybe_dispatch_backfill(filter_spec.dispatch_immediately?, job, opts, enqueued)

      {:error, _} ->
        {:cont, acc}
    end
  end

  defp maybe_dispatch_backfill(false, _job, _opts, enqueued), do: {:cont, enqueued}

  defp maybe_dispatch_backfill(true, job, opts, enqueued) do
    case VisualIndexDispatcher.dispatch_job(job, opts) do
      {:ok, _} -> {:cont, enqueued}
      {:error, :dispatch_superseded} -> {:cont, enqueued}
      {:error, {:publish_failed, _}} -> {:cont, enqueued}
      {:error, _} = error -> {:halt, error}
    end
  end

  defp query_playable_catalog_batch(spec) do
    query =
      RecordingCatalogEntry
      |> Ash.Query.filter(
        not is_nil(recording_block_id) and
          local_state != :quarantined and
          is_nil(quarantine_reason) and
          (local_state == :present or archive_state == :verified)
      )
      |> maybe_filter_eq(:camera_source_id, spec.camera_source_id)
      |> maybe_filter_eq(:stream_profile_id, spec.stream_profile_id)
      |> maybe_filter_window(spec.from_us, spec.to_us)
      |> maybe_filter_cursor(spec.cursor_id)
      |> Ash.Query.sort(id: :asc)
      |> Ash.Query.limit(spec.limit)

    Ash.read!(query, actor: @system_actor)
  end

  defp maybe_filter_eq(query, _field, nil), do: query

  defp maybe_filter_eq(query, :camera_source_id, id),
    do: Ash.Query.filter(query, camera_source_id == ^id)

  defp maybe_filter_eq(query, :stream_profile_id, id),
    do: Ash.Query.filter(query, stream_profile_id == ^id)

  defp maybe_filter_window(query, nil, nil), do: query

  defp maybe_filter_window(query, from_us, nil) when is_integer(from_us) do
    Ash.Query.filter(query, timeline_end_us > ^from_us)
  end

  defp maybe_filter_window(query, nil, to_us) when is_integer(to_us) do
    Ash.Query.filter(query, timeline_start_us < ^to_us)
  end

  defp maybe_filter_window(query, from_us, to_us)
       when is_integer(from_us) and is_integer(to_us) do
    Ash.Query.filter(query, timeline_start_us < ^to_us and timeline_end_us > ^from_us)
  end

  defp maybe_filter_cursor(query, nil), do: query
  defp maybe_filter_cursor(query, cursor_id), do: Ash.Query.filter(query, id > ^cursor_id)

  defp load_recording_blocks_map([]), do: %{}

  defp load_recording_blocks_map(entries) do
    block_ids =
      entries
      |> Enum.map(& &1.recording_block_id)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    if block_ids == [] do
      %{}
    else
      RecordingBlock
      |> Ash.Query.filter(id in ^block_ids)
      |> Ash.read!(actor: @system_actor)
      |> Map.new(&{to_string(&1.id), &1})
    end
  end

  defp load_policies_map([]), do: %{}

  defp load_policies_map(entries) do
    cam_ids = entries |> Enum.map(& &1.camera_source_id) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    if cam_ids == [] do
      %{}
    else
      CameraRecordingPolicy
      |> Ash.Query.filter(camera_source_id in ^cam_ids)
      |> Ash.read!(actor: @system_actor)
      |> Map.new(fn p ->
        {{to_string(p.camera_source_id), to_string(p.stream_profile_id)}, p}
      end)
    end
  end

  defp load_existing_jobs_map([], _mc), do: %{}

  defp load_existing_jobs_map(entries, mc) do
    entry_ids = Enum.map(entries, & &1.id)
    emb_id = mc.embedder_model_id
    emb_ver = mc.embedder_model_version

    VisualIndexJob
    |> Ash.Query.filter(
      catalog_entry_id in ^entry_ids and
        embedder_model_id == ^emb_id and
        embedder_model_version == ^emb_ver
    )
    |> Ash.read!(actor: @system_actor)
    |> Map.new(&{to_string(&1.catalog_entry_id), &1})
  end

  defp maybe_prune_orphan_frames(false, _batch_size), do: {:ok, 0}

  defp maybe_prune_orphan_frames(true, batch_size) do
    sql = """
    DELETE FROM platform.camera_visual_frames f
    WHERE f.ctid IN (
      SELECT vf.ctid
      FROM platform.camera_visual_frames vf
      WHERE NOT EXISTS (
        SELECT 1
        FROM platform.camera_visual_embeddings ve
        WHERE ve.visual_frame_id = vf.id
      )
      LIMIT $1
    )
    """

    case SQL.query(Repo, sql, [batch_size]) do
      {:ok, %{num_rows: n}} -> {:ok, n}
      {:error, _} = err -> err
    end
  end

  # ---------------------------------------------------------------------------
  # Validation & authorization
  # ---------------------------------------------------------------------------

  defp validate_backfill_params(attrs, opts) do
    base_cfg = VisualIndexDispatcher.active_model_config(opts)

    model_cfg = %{
      detector_model_id:
        non_empty_string(fetch_val(attrs, :detector_model_id)) || base_cfg.detector_model_id,
      detector_model_version:
        non_empty_string(fetch_val(attrs, :detector_model_version)) ||
          base_cfg.detector_model_version,
      embedder_model_id:
        non_empty_string(fetch_val(attrs, :embedder_model_id) || fetch_val(attrs, :model_id)) ||
          base_cfg.embedder_model_id,
      embedder_model_version:
        non_empty_string(
          fetch_val(attrs, :embedder_model_version) || fetch_val(attrs, :model_version)
        ) ||
          base_cfg.embedder_model_version,
      embedding_dim:
        case fetch_val(attrs, :embedding_dim) do
          512 -> 512
          768 -> 768
          _ -> base_cfg.embedding_dim
        end
    }

    with {:ok, cam_id} <-
           cast_optional_uuid(fetch_val(attrs, :camera_source_id), :invalid_camera_source_id),
         {:ok, prof_id} <-
           cast_optional_uuid(fetch_val(attrs, :stream_profile_id), :invalid_stream_profile_id),
         {:ok, cursor_id} <- cast_optional_uuid(fetch_val(attrs, :cursor_id), :invalid_cursor_id),
         {:ok, from_us, to_us} <- validate_optional_window(attrs) do
      limit = clamp_int(fetch_val(attrs, :limit) || @default_batch_limit, 1, @max_batch_limit)

      min_interval_ms =
        case fetch_val(attrs, :min_interval_ms) do
          v when is_integer(v) -> clamp_int(v, 500, 60_000)
          _ -> nil
        end

      max_frames =
        case fetch_val(attrs, :max_frames_per_block) do
          v when is_integer(v) -> clamp_int(v, 1, 512)
          _ -> nil
        end

      {:ok,
       %{
         camera_source_id: cam_id,
         stream_profile_id: prof_id,
         cursor_id: cursor_id,
         from_us: from_us,
         to_us: to_us,
         limit: limit,
         model_cfg: model_cfg,
         min_interval_ms: min_interval_ms,
         max_frames_per_block: max_frames,
         force?: fetch_val(attrs, :force?) == true,
         dispatch_immediately?: fetch_val(attrs, :dispatch_immediately?) == true
       }}
    end
  end

  defp validate_optional_window(attrs) do
    from_us = fetch_val(attrs, :from_us)
    to_us = fetch_val(attrs, :to_us)

    cond do
      is_nil(from_us) and is_nil(to_us) ->
        {:ok, nil, nil}

      is_integer(from_us) and is_nil(to_us) and from_us >= 0 ->
        {:ok, from_us, nil}

      is_nil(from_us) and is_integer(to_us) and to_us > 0 ->
        {:ok, nil, to_us}

      is_integer(from_us) and is_integer(to_us) and from_us >= 0 and to_us > from_us ->
        {:ok, from_us, to_us}

      true ->
        {:error, :invalid_time_window}
    end
  end

  defp validate_cleanup_params(attrs, opts) do
    base_cfg = VisualIndexDispatcher.active_model_config(opts)

    keep_id =
      non_empty_string(fetch_val(attrs, :keep_model_id) || fetch_val(attrs, :model_id)) ||
        base_cfg.embedder_model_id

    keep_ver =
      non_empty_string(fetch_val(attrs, :keep_model_version) || fetch_val(attrs, :model_version)) ||
        base_cfg.embedder_model_version

    batch_size =
      clamp_int(
        fetch_val(attrs, :batch_size) || @default_cleanup_batch_size,
        1,
        @max_cleanup_batch_size
      )

    prune_frames? = fetch_val(attrs, :prune_orphan_frames?) != false

    {:ok, keep_id, keep_ver, batch_size, prune_frames?}
  end

  defp authorize_optional_operator(opts) do
    scope = Keyword.get(opts, :scope)
    actor = Keyword.get(opts, :actor) || actor_from_scope(scope)

    cond do
      is_nil(actor) and is_nil(scope) ->
        :ok

      match?(%{role: :system}, actor) or match?(%{role: "system"}, actor) ->
        :ok

      is_map(actor) ->
        perms =
          case {scope, actor} do
            {%{permissions: %MapSet{} = p}, _} -> p
            {_, %{permissions: %MapSet{} = p}} -> p
            {%{user: u}, _} when is_map(u) -> RBAC.permissions_for_user(u)
            _ -> RBAC.permissions_for_user(actor)
          end

        if Enum.any?(@operate_permissions, &RBAC.Catalog.holds?(perms, &1)) do
          :ok
        else
          {:error, Forbidden.exception([])}
        end

      true ->
        {:error, Forbidden.exception([])}
    end
  end

  defp actor_from_scope(%{user: user, permissions: %MapSet{} = p}) when is_map(user),
    do: Map.put(user, :permissions, p)

  defp actor_from_scope(%{user: user}) when is_map(user), do: user
  defp actor_from_scope(%{actor: actor}) when is_map(actor), do: actor
  defp actor_from_scope(_), do: nil

  defp cast_optional_uuid(nil, _err_tag), do: {:ok, nil}
  defp cast_optional_uuid("", _err_tag), do: {:ok, nil}

  defp cast_optional_uuid(val, err_tag) when is_binary(val) do
    case Ecto.UUID.cast(String.trim(val)) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, err_tag}
    end
  end

  defp cast_optional_uuid(_, err_tag), do: {:error, err_tag}

  defp non_empty_string(v) when is_binary(v) do
    trimmed = String.trim(v)
    if trimmed == "", do: nil, else: trimmed
  end

  defp non_empty_string(_), do: nil

  defp clamp_int(v, min_v, max_v) when is_integer(v), do: v |> max(min_v) |> min(max_v)
  defp clamp_int(_, min_v, _max_v), do: min_v

  defp to_map(m) when is_map(m), do: m
  defp to_map(l) when is_list(l), do: Map.new(l)

  defp fetch_val(map, key) when is_map(map) and is_atom(key) do
    case Map.fetch(map, key) do
      {:ok, val} -> val
      :error -> Map.get(map, Atom.to_string(key))
    end
  end
end
