defmodule ServiceRadarWebNG.SRQL.CameraObservationsQuery do
  @moduledoc """
  Scoped Ash query executor for SRQL `in:camera_observations` read-model plans.

  Enforces:
  - Both `devices.view` and `devices.cameras.recordings.view` RBAC permissions.
  - Per-camera `ServiceRadar.Camera.Source` scope resolution (intersected with
    `scope.authorized_camera_source_ids` when present) pushed into SQL.
  - Playable, non-quarantined `RecordingCatalogEntry` liveness for
    `:recorded_block` observations (or `:live_keyframe_tap` on authorized
    cameras).
  - SQL-pushed filtering, sorting, and pagination without ever selecting
    `crop_jpeg`.
  """

  import Ash.Expr

  alias ServiceRadar.Camera.Source
  alias ServiceRadar.Camera.VantageObservation
  alias ServiceRadarWebNG.SRQL.EntityAccess

  require Ash.Query
  require Ash.Sort

  @uuid_fields ~w(id job_id catalog_entry_id camera_source_id stream_profile_id)
  @time_fields ~w(inserted_at updated_at)
  @enum_fields ~w(source_mode time_basis)

  @field_atoms %{
    "id" => :id,
    "observation_key" => :observation_key,
    "pack_id" => :pack_id,
    "pipeline_id" => :pipeline_id,
    "pipeline_version" => :pipeline_version,
    "worker_kind" => :worker_kind,
    "worker_id" => :worker_id,
    "model_id" => :model_id,
    "model_version" => :model_version,
    "job_id" => :job_id,
    "catalog_entry_id" => :catalog_entry_id,
    "camera_source_id" => :camera_source_id,
    "stream_profile_id" => :stream_profile_id,
    "source_mode" => :source_mode,
    "fragment_sequence" => :fragment_sequence,
    "frame_sequence" => :frame_sequence,
    "media_pts_ns" => :media_pts_ns,
    "timeline_ts_us" => :timeline_ts_us,
    "time_basis" => :time_basis,
    "track_id" => :track_id,
    "category" => :category,
    "label" => :label,
    "confidence" => :confidence,
    "bbox" => :bbox,
    "attributes" => :attributes,
    "signal_schema_id" => :signal_schema_id,
    "signal_schema_version" => :signal_schema_version,
    "display_contract_id" => :display_contract_id,
    "inserted_at" => :inserted_at,
    "updated_at" => :updated_at
  }

  @select_fields [
    :id,
    :observation_key,
    :pack_id,
    :pipeline_id,
    :pipeline_version,
    :worker_kind,
    :worker_id,
    :model_id,
    :model_version,
    :job_id,
    :catalog_entry_id,
    :camera_source_id,
    :stream_profile_id,
    :source_mode,
    :fragment_sequence,
    :frame_sequence,
    :media_pts_ns,
    :timeline_ts_us,
    :time_basis,
    :track_id,
    :category,
    :label,
    :confidence,
    :bbox,
    :attributes,
    :signal_schema_id,
    :signal_schema_version,
    :display_contract_id,
    :inserted_at,
    :updated_at
  ]

  @source_mode_map Map.new(VantageObservation.source_modes(), &{Atom.to_string(&1), &1})
  @time_basis_map Map.new(VantageObservation.time_bases(), &{Atom.to_string(&1), &1})

  @spec execute(map(), term()) :: {:ok, Postgrex.Result.t()} | {:error, term()}
  def execute(%{"entity" => "camera_observations"} = plan, scope) do
    fields = Map.fetch!(plan, "fields")

    with :ok <- EntityAccess.authorize("in:camera_observations", scope),
         {:ok, source_names_by_id} <- load_authorized_sources(scope) do
      authorized_ids = Map.keys(source_names_by_id)

      if authorized_ids == [] do
        {:ok, %Postgrex.Result{columns: fields, rows: []}}
      else
        with {:ok, query} <- build_query(plan, scope, authorized_ids, source_names_by_id),
             {:ok, observations} <- Ash.read(query, scope: scope) do
          rows = Enum.map(observations, fn obs -> project_row(obs, fields, source_names_by_id) end)

          {:ok, %Postgrex.Result{columns: fields, rows: rows}}
        end
      end
    end
  rescue
    _error in Ash.Error.Forbidden -> {:error, :forbidden}
    error in Ash.Error.Invalid -> {:error, error}
  end

  defp load_authorized_sources(scope) do
    query =
      Source
      |> Ash.Query.for_read(:read, %{}, scope: scope)
      |> Ash.Query.select([:id, :display_name])

    with {:ok, sources} <- Ash.read(query, scope: scope) do
      explicit_allow = extract_explicit_allowed_camera_ids(scope)

      by_id =
        Enum.reduce(sources, %{}, fn source, acc ->
          id = to_string(source.id)

          if is_nil(explicit_allow) or MapSet.member?(explicit_allow, id) do
            Map.put(acc, id, source.display_name)
          else
            acc
          end
        end)

      {:ok, by_id}
    end
  end

  defp extract_explicit_allowed_camera_ids(scope) when is_map(scope) do
    candidates = [
      Map.get(scope, :authorized_camera_source_ids),
      case Map.get(scope, :user) do
        %{} = user -> Map.get(user, :authorized_camera_source_ids)
        _ -> nil
      end
    ]

    case Enum.find(candidates, &(is_list(&1) or match?(%MapSet{}, &1))) do
      nil ->
        nil

      items ->
        Enum.reduce(items, MapSet.new(), fn item, acc ->
          case Ecto.UUID.cast(to_string(item)) do
            {:ok, uuid} -> MapSet.put(acc, uuid)
            :error -> acc
          end
        end)
    end
  end

  defp extract_explicit_allowed_camera_ids(_scope), do: nil

  @doc false
  def build_query(plan, scope, authorized_ids, source_names_by_id) do
    base =
      VantageObservation
      |> Ash.Query.for_read(:read, %{}, scope: scope)
      |> Ash.Query.filter(
        camera_source_id in ^authorized_ids and
          ((source_mode == :live_keyframe_tap and is_nil(catalog_entry_id)) or
             (not is_nil(catalog_entry_id) and
                not is_nil(catalog_entry.recording_block_id) and
                catalog_entry.local_state != :quarantined and
                is_nil(catalog_entry.quarantine_reason) and
                (catalog_entry.local_state == :present or catalog_entry.archive_state == :verified)))
      )
      |> Ash.Query.select(@select_fields)
      |> Ash.Query.load([:has_crop])

    with {:ok, with_time} <- apply_time_range(base, plan["time_range"]),
         {:ok, with_filters} <- apply_filters(with_time, plan["filters"] || [], source_names_by_id),
         {:ok, with_sort} <- apply_sort(with_filters, plan["order"] || []) do
      {:ok,
       with_sort
       |> maybe_apply_limit(plan["limit"])
       |> maybe_apply_offset(plan["offset"])}
    end
  end

  defp apply_time_range(query, nil), do: {:ok, query}

  defp apply_time_range(query, %{"start" => start_iso, "end" => end_iso}) do
    with {:ok, start_dt, _} <- DateTime.from_iso8601(start_iso),
         {:ok, end_dt, _} <- DateTime.from_iso8601(end_iso) do
      start_us = DateTime.to_unix(start_dt, :microsecond)
      end_us = DateTime.to_unix(end_dt, :microsecond)
      {:ok, Ash.Query.filter(query, timeline_ts_us >= ^start_us and timeline_ts_us <= ^end_us)}
    else
      _ -> {:error, :invalid_request}
    end
  end

  defp apply_time_range(_query, _), do: {:error, :invalid_request}

  defp apply_filters(query, filters, source_names_by_id) do
    Enum.reduce_while(filters, {:ok, query}, fn filter, {:ok, acc} ->
      case apply_single_filter(acc, filter, source_names_by_id) do
        {:ok, next_query} -> {:cont, {:ok, next_query}}
        {:error, _reason} = err -> {:halt, err}
      end
    end)
  end

  defp apply_single_filter(query, %{"field" => "search", "op" => op, "value" => value}, _sources) do
    case op do
      "eq" when is_binary(value) ->
        {:ok,
         Ash.Query.filter(
           query,
           expr(fragment("search_tsv @@ websearch_to_tsquery('english', ?)", ^value))
         )}

      "not_eq" when is_binary(value) ->
        {:ok,
         Ash.Query.filter(
           query,
           expr(not fragment("search_tsv @@ websearch_to_tsquery('english', ?)", ^value))
         )}

      "in" when is_list(value) ->
        terms = Enum.filter(value, &is_binary/1)

        if terms == [] do
          {:ok, Ash.Query.filter(query, expr(false))}
        else
          {:ok,
           Ash.Query.filter(
             query,
             expr(
               fragment(
                 "EXISTS (SELECT 1 FROM unnest(?::text[]) AS t WHERE search_tsv @@ websearch_to_tsquery('english', t))",
                 ^terms
               )
             )
           )}
        end

      "not_in" when is_list(value) ->
        terms = Enum.filter(value, &is_binary/1)

        if terms == [] do
          {:ok, query}
        else
          {:ok,
           Ash.Query.filter(
             query,
             expr(
               not fragment(
                 "EXISTS (SELECT 1 FROM unnest(?::text[]) AS t WHERE search_tsv @@ websearch_to_tsquery('english', t))",
                 ^terms
               )
             )
           )}
        end

      "like" when is_binary(value) ->
        {:ok,
         Ash.Query.filter(
           query,
           expr(fragment("label ILIKE ? OR search_text ILIKE ?", ^value, ^value))
         )}

      "not_like" when is_binary(value) ->
        {:ok,
         Ash.Query.filter(
           query,
           expr(not fragment("COALESCE(label, '') ILIKE ? OR COALESCE(search_text, '') ILIKE ?", ^value, ^value))
         )}

      _ ->
        {:error, :invalid_request}
    end
  end

  defp apply_single_filter(query, %{"field" => "has_crop", "op" => op, "value" => value}, _sources) do
    case {op, value} do
      {"eq", true} ->
        {:ok, Ash.Query.filter(query, expr(not is_nil(crop_jpeg)))}

      {"eq", false} ->
        {:ok, Ash.Query.filter(query, expr(is_nil(crop_jpeg)))}

      {"not_eq", true} ->
        {:ok, Ash.Query.filter(query, expr(is_nil(crop_jpeg)))}

      {"not_eq", false} ->
        {:ok, Ash.Query.filter(query, expr(not is_nil(crop_jpeg)))}

      {"in", values} when is_list(values) ->
        has_t = true in values
        has_f = false in values

        cond do
          has_t and has_f -> {:ok, query}
          has_t -> {:ok, Ash.Query.filter(query, expr(not is_nil(crop_jpeg)))}
          has_f -> {:ok, Ash.Query.filter(query, expr(is_nil(crop_jpeg)))}
          true -> {:ok, Ash.Query.filter(query, expr(false))}
        end

      {"not_in", values} when is_list(values) ->
        has_t = true in values
        has_f = false in values

        cond do
          has_t and has_f -> {:ok, Ash.Query.filter(query, expr(false))}
          has_t -> {:ok, Ash.Query.filter(query, expr(is_nil(crop_jpeg)))}
          has_f -> {:ok, Ash.Query.filter(query, expr(not is_nil(crop_jpeg)))}
          true -> {:ok, query}
        end

      _ ->
        {:error, :invalid_request}
    end
  end

  defp apply_single_filter(query, %{"field" => "camera_display_name", "op" => op, "value" => value}, source_names_by_id) do
    matching_ids =
      source_names_by_id
      |> Enum.filter(fn {_id, name} -> match_display_name?(name, op, value) end)
      |> Enum.map(&elem(&1, 0))

    case matching_ids do
      [] -> {:ok, Ash.Query.filter(query, expr(false))}
      ids -> {:ok, Ash.Query.filter(query, camera_source_id in ^ids)}
    end
  end

  defp apply_single_filter(query, %{"field" => field, "op" => op, "value" => value}, _sources)
       when field in @enum_fields do
    enum_map = if field == "source_mode", do: @source_mode_map, else: @time_basis_map
    field_atom = Map.fetch!(@field_atoms, field)

    case op do
      "eq" when is_binary(value) ->
        case Map.fetch(enum_map, value) do
          {:ok, atom_val} -> {:ok, apply_attr_op(query, field_atom, "eq", atom_val)}
          :error -> {:ok, Ash.Query.filter(query, expr(false))}
        end

      "not_eq" when is_binary(value) ->
        case Map.fetch(enum_map, value) do
          {:ok, atom_val} -> {:ok, apply_attr_op(query, field_atom, "not_eq", atom_val)}
          :error -> {:ok, query}
        end

      "in" when is_list(value) ->
        atoms =
          Enum.flat_map(value, fn item ->
            case Map.fetch(enum_map, item) do
              {:ok, atom_val} -> [atom_val]
              :error -> []
            end
          end)

        if atoms == [] do
          {:ok, Ash.Query.filter(query, expr(false))}
        else
          {:ok, apply_attr_op(query, field_atom, "in", atoms)}
        end

      "not_in" when is_list(value) ->
        atoms =
          Enum.flat_map(value, fn item ->
            case Map.fetch(enum_map, item) do
              {:ok, atom_val} -> [atom_val]
              :error -> []
            end
          end)

        if atoms == [] do
          {:ok, query}
        else
          {:ok, apply_attr_op(query, field_atom, "not_in", atoms)}
        end

      "like" when is_binary(value) ->
        col_ref = ref(field_atom)
        {:ok, Ash.Query.filter(query, expr(fragment("?::text ILIKE ?", ^col_ref, ^value)))}

      "not_like" when is_binary(value) ->
        col_ref = ref(field_atom)
        {:ok, Ash.Query.filter(query, expr(not fragment("COALESCE(?::text, '') ILIKE ?", ^col_ref, ^value)))}

      _ ->
        {:error, :invalid_request}
    end
  end

  defp apply_single_filter(query, %{"field" => field, "op" => op, "value" => value}, _sources) do
    with {:ok, field_atom} <- fetch_field_atom(field),
         {:ok, normalized_val} <- normalize_filter_value(field, op, value) do
      {:ok, apply_attr_op(query, field_atom, op, normalized_val)}
    end
  end

  defp apply_single_filter(_query, _filter, _sources), do: {:error, :invalid_request}

  defp fetch_field_atom(field) do
    case Map.fetch(@field_atoms, field) do
      {:ok, atom} -> {:ok, atom}
      :error -> {:error, :invalid_request}
    end
  end

  defp normalize_filter_value(field, op, value) when field in @uuid_fields do
    if op in ["like", "not_like"] do
      {:error, :invalid_request}
    else
      cast_uuids(value)
    end
  end

  defp normalize_filter_value(field, _op, value) when field in @time_fields do
    cast_datetimes(value)
  end

  defp normalize_filter_value(_field, _op, value), do: {:ok, value}

  defp cast_uuids(values) when is_list(values) do
    values
    |> Enum.reduce_while({:ok, []}, fn val, {:ok, acc} ->
      case cast_uuids(val) do
        {:ok, uuid} -> {:cont, {:ok, [uuid | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, list} -> {:ok, Enum.reverse(list)}
      err -> err
    end
  end

  defp cast_uuids(val) when is_binary(val) do
    case Ecto.UUID.cast(String.trim(val)) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :invalid_request}
    end
  end

  defp cast_uuids(_), do: {:error, :invalid_request}

  defp cast_datetimes(values) when is_list(values) do
    values
    |> Enum.reduce_while({:ok, []}, fn val, {:ok, acc} ->
      case cast_datetimes(val) do
        {:ok, dt} -> {:cont, {:ok, [dt | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, list} -> {:ok, Enum.reverse(list)}
      err -> err
    end
  end

  defp cast_datetimes(val) when is_binary(val) do
    case DateTime.from_iso8601(val) do
      {:ok, dt, _offset} -> {:ok, dt}
      _ -> {:error, :invalid_request}
    end
  end

  defp cast_datetimes(_), do: {:error, :invalid_request}

  defp apply_attr_op(query, field_atom, "eq", value), do: Ash.Query.filter_input(query, %{field_atom => %{eq: value}})

  defp apply_attr_op(query, field_atom, "not_eq", value),
    do: Ash.Query.filter_input(query, %{field_atom => %{not_eq: value}})

  defp apply_attr_op(query, field_atom, "in", value), do: Ash.Query.filter_input(query, %{field_atom => %{in: value}})

  defp apply_attr_op(query, field_atom, "not_in", value),
    do: Ash.Query.filter_input(query, %{not: %{field_atom => %{in: value}}})

  defp apply_attr_op(query, field_atom, "gt", value), do: Ash.Query.filter_input(query, %{field_atom => %{gt: value}})

  defp apply_attr_op(query, field_atom, "gte", value), do: Ash.Query.filter_input(query, %{field_atom => %{gte: value}})

  defp apply_attr_op(query, field_atom, "lt", value), do: Ash.Query.filter_input(query, %{field_atom => %{lt: value}})

  defp apply_attr_op(query, field_atom, "lte", value), do: Ash.Query.filter_input(query, %{field_atom => %{lte: value}})

  defp apply_attr_op(query, field_atom, "like", value) do
    col_ref = ref(field_atom)
    Ash.Query.filter(query, expr(fragment("? ILIKE ?", ^col_ref, ^value)))
  end

  defp apply_attr_op(query, field_atom, "not_like", value) do
    col_ref = ref(field_atom)
    Ash.Query.filter(query, expr(not fragment("COALESCE(?, '') ILIKE ?", ^col_ref, ^value)))
  end

  defp match_display_name?(name, op, value) do
    actual = name || ""

    case op do
      "eq" when is_binary(value) -> actual == value
      "not_eq" when is_binary(value) -> actual != value
      "in" when is_list(value) -> actual in value
      "not_in" when is_list(value) -> actual not in value
      "like" when is_binary(value) -> like_match?(actual, value)
      "not_like" when is_binary(value) -> not like_match?(actual, value)
      _ -> false
    end
  end

  defp like_match?(actual, pattern) do
    regex = pattern |> Regex.escape() |> String.replace("%", ".*") |> String.replace("_", ".")
    Regex.match?(Regex.compile!("\\A" <> regex <> "\\z", "isu"), actual)
  end

  defp apply_sort(query, order) do
    clauses =
      Enum.reduce_while(order, {:ok, []}, fn %{"field" => field, "direction" => dir}, {:ok, acc} ->
        dir_atom = if dir == "asc", do: :asc, else: :desc

        case field do
          "camera_display_name" ->
            nulls_dir = if dir == "asc", do: :asc_nils_last, else: :desc_nils_last
            {:cont, {:ok, [{Ash.Sort.expr_sort(camera_source.display_name, :string), nulls_dir} | acc]}}

          "has_crop" ->
            {:cont, {:ok, [{:has_crop, dir_atom} | acc]}}

          _ ->
            case Map.fetch(@field_atoms, field) do
              {:ok, field_atom} -> {:cont, {:ok, [{field_atom, dir_atom} | acc]}}
              :error -> {:halt, {:error, :invalid_request}}
            end
        end
      end)

    case clauses do
      {:ok, rev_clauses} ->
        {:ok, Ash.Query.sort(query, Enum.reverse(rev_clauses))}

      {:error, _} = err ->
        err
    end
  end

  defp maybe_apply_limit(query, limit) when is_integer(limit) and limit > 0, do: Ash.Query.limit(query, limit)

  defp maybe_apply_limit(query, _), do: query

  defp maybe_apply_offset(query, offset) when is_integer(offset) and offset > 0, do: Ash.Query.offset(query, offset)

  defp maybe_apply_offset(query, _), do: query

  defp project_row(obs, fields, source_names_by_id) do
    Enum.map(fields, fn field ->
      project_field(obs, field, source_names_by_id)
    end)
  end

  defp project_field(obs, "camera_display_name", source_names_by_id),
    do: Map.get(source_names_by_id, to_string(obs.camera_source_id))

  defp project_field(obs, "has_crop", _sources), do: obs.has_crop == true

  defp project_field(obs, field, _sources) do
    case Map.fetch(@field_atoms, field) do
      {:ok, atom} ->
        case Map.get(obs, atom) do
          val when is_atom(val) and val not in [nil, true, false] -> Atom.to_string(val)
          val -> val
        end

      :error ->
        nil
    end
  end
end
