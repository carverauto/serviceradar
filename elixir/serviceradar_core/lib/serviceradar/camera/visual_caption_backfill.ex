defmodule ServiceRadar.Camera.VisualCaptionBackfill do
  @moduledoc """
  Bounded historical backfill scheduler for Smart camera clip VLM captions.

  Scans playable, non-quarantined `RecordingCatalogEntry` blocks that already
  have indexed `camera_visual_frames` with `thumbnail_jpeg` and at least one
  Smart detection (`person`, `animal`, `vehicle`, `package`), and enqueues
  idempotent `ServiceRadar.Camera.VisualCaptionWorker` jobs for any entry
  missing a caption for the active `(vlm_model_id, prompt_version)`.
  """

  alias Ash.Error.Forbidden
  alias Ecto.Adapters.SQL
  alias ServiceRadar.Camera.VisualCaptionClient
  alias ServiceRadar.Camera.VisualCaptionWorker
  alias ServiceRadar.Identity.RBAC
  alias ServiceRadar.Repo

  @operate_permissions ["settings.recording.manage", "settings.recording.operate"]
  @default_batch_limit 100
  @max_batch_limit 500
  @smart_classes ~w(person animal vehicle package)

  @doc """
  Enqueues `VisualCaptionWorker` jobs for playable Smart clips missing captions
  for the configured `(vlm_model_id, prompt_version)`.
  """
  @spec enqueue_missing(map() | keyword(), keyword()) :: {:ok, map()} | {:error, term()}
  def enqueue_missing(params \\ %{}, opts \\ [])
      when (is_map(params) or is_list(params)) and is_list(opts) do
    attrs = to_map(params)

    with :ok <- authorize_optional_operator(opts),
         {:ok, spec} <- validate_params(attrs, opts),
         {:ok, candidates} <- load_candidates(spec, opts) do
      enqueue_fn =
        Keyword.get(opts, :enqueue_fn, fn catalog_entry_id, frame_id ->
          VisualCaptionWorker.enqueue_for_entry(catalog_entry_id, frame_id,
            enabled_fn: Keyword.get(opts, :enabled_fn, fn -> true end)
          )
        end)

      summary =
        Enum.reduce_while(
          candidates,
          %{
            scanned_count: 0,
            enqueued_count: 0,
            skipped_count: 0,
            catalog_entry_ids: [],
            next_cursor_id: nil
          },
          fn candidate, acc ->
            acc = %{acc | scanned_count: acc.scanned_count + 1}

            case enqueue_fn.(candidate.catalog_entry_id, candidate.visual_frame_id) do
              {:ok, _job} ->
                {:cont,
                 %{
                   acc
                   | enqueued_count: acc.enqueued_count + 1,
                     catalog_entry_ids: [candidate.catalog_entry_id | acc.catalog_entry_ids]
                 }}

              :noop ->
                {:cont, %{acc | skipped_count: acc.skipped_count + 1}}

              {:error, _} = err ->
                {:halt, err}
            end
          end
        )

      case summary do
        {:error, _} = err ->
          err

        acc ->
          next_cursor =
            if length(candidates) == spec.limit do
              List.last(candidates).catalog_entry_id
            end

          {:ok,
           %{
             acc
             | catalog_entry_ids: Enum.reverse(acc.catalog_entry_ids),
               next_cursor_id: next_cursor
           }}
      end
    end
  end

  defp load_candidates(spec, opts) do
    case Keyword.get(opts, :candidates_loader) do
      fun when is_function(fun, 1) ->
        fun.(spec)

      _ ->
        query_missing_smart_entries(spec)
    end
  end

  defp query_missing_smart_entries(spec) do
    {extra_sql, extra_params, next_idx} = build_filters(spec, 4)
    limit_idx = next_idx

    missing_clause =
      if spec.force? do
        ""
      else
        """
        AND NOT EXISTS (
          SELECT 1
          FROM platform.camera_visual_clip_captions cap
          WHERE cap.catalog_entry_id = c.id
            AND cap.vlm_model_id = $2
            AND cap.prompt_version = $3
        )
        """
      end

    sql = """
    SELECT
      c.id AS catalog_entry_id,
      (
        SELECT f2.id
        FROM platform.camera_visual_frames f2
        WHERE f2.catalog_entry_id = c.id
          AND f2.thumbnail_jpeg IS NOT NULL
        ORDER BY f2.timeline_ts_us ASC
        LIMIT 1
      ) AS visual_frame_id
    FROM platform.camera_recording_catalog c
    WHERE c.recording_block_id IS NOT NULL
      AND c.local_state <> 'quarantined'
      AND c.quarantine_reason IS NULL
      AND (c.local_state = 'present' OR c.archive_state = 'verified')
      AND EXISTS (
        SELECT 1
        FROM platform.camera_visual_frames f
        WHERE f.catalog_entry_id = c.id
          AND f.thumbnail_jpeg IS NOT NULL
          AND EXISTS (
            SELECT 1
            FROM unnest(f.detections) AS det
            WHERE lower(det->>'object_class') = ANY($1::text[])
          )
      )
      #{missing_clause}
      #{extra_sql}
    ORDER BY c.id ASC
    LIMIT $#{limit_idx}
    """

    params =
      [@smart_classes, spec.vlm_model_id, spec.prompt_version] ++ extra_params ++ [spec.limit]

    case SQL.query(Repo, sql, params) do
      {:ok, %{rows: rows}} ->
        candidates =
          Enum.map(rows, fn [entry_id, frame_id] ->
            %{
              catalog_entry_id: decode_uuid(entry_id),
              visual_frame_id: if(frame_id, do: decode_uuid(frame_id))
            }
          end)

        {:ok, candidates}

      {:error, _} = err ->
        err
    end
  end

  defp build_filters(spec, start_idx) do
    {clauses, params, idx} =
      {[], [], start_idx}
      |> maybe_add_uuid("c.camera_source_id =", spec.camera_source_id)
      |> maybe_add_uuid("c.id >", spec.cursor_id)
      |> maybe_add_int("c.timeline_end_us >", spec.from_us)
      |> maybe_add_int("c.timeline_start_us <", spec.to_us)

    sql =
      case Enum.reverse(clauses) do
        [] -> ""
        list -> "AND " <> Enum.join(list, "\n      AND ")
      end

    {sql, Enum.reverse(params), idx}
  end

  defp maybe_add_uuid(acc, _expr, nil), do: acc

  defp maybe_add_uuid({clauses, params, idx}, expr, uuid) do
    {["#{expr} $#{idx}::uuid" | clauses], [Ecto.UUID.dump!(uuid) | params], idx + 1}
  end

  defp maybe_add_int(acc, _expr, nil), do: acc

  defp maybe_add_int({clauses, params, idx}, expr, val) do
    {["#{expr} $#{idx}" | clauses], [val | params], idx + 1}
  end

  defp validate_params(attrs, opts) do
    with {:ok, cam_id} <-
           cast_optional_uuid(fetch_val(attrs, :camera_source_id), :invalid_camera_source_id),
         {:ok, cursor_id} <- cast_optional_uuid(fetch_val(attrs, :cursor_id), :invalid_cursor_id),
         {:ok, from_us, to_us} <- validate_window(attrs) do
      limit = clamp_int(fetch_val(attrs, :limit) || @default_batch_limit, 1, @max_batch_limit)

      {:ok,
       %{
         camera_source_id: cam_id,
         cursor_id: cursor_id,
         from_us: from_us,
         to_us: to_us,
         limit: limit,
         force?: fetch_val(attrs, :force?) == true,
         vlm_model_id:
           non_empty_string(fetch_val(attrs, :vlm_model_id)) ||
             VisualCaptionClient.vlm_model_id(opts),
         prompt_version:
           non_empty_string(fetch_val(attrs, :prompt_version)) ||
             VisualCaptionClient.prompt_version(opts)
       }}
    end
  end

  defp validate_window(attrs) do
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

  defp cast_optional_uuid(nil, _err), do: {:ok, nil}
  defp cast_optional_uuid("", _err), do: {:ok, nil}

  defp cast_optional_uuid(val, err) when is_binary(val) do
    case Ecto.UUID.cast(String.trim(val)) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, err}
    end
  end

  defp cast_optional_uuid(_, err), do: {:error, err}

  defp decode_uuid(<<_::128>> = bin) do
    case Ecto.UUID.load(bin) do
      {:ok, str} -> str
      :error -> bin
    end
  end

  defp decode_uuid(str) when is_binary(str), do: str
  defp decode_uuid(other), do: to_string(other)

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
