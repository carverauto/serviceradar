defmodule ServiceRadarWebNG.SRQL do
  @moduledoc false

  # Use ServiceRadar.Repo directly for Ecto.Adapters.SQL operations
  # (The wrapper module ServiceRadarWebNG.Repo doesn't work with SQL adapter functions)
  alias ServiceRadar.Repo
  alias ServiceRadarWebNG.SRQL.AshAdapter
  alias ServiceRadarWebNG.SRQL.Native

  require Logger

  @behaviour ServiceRadarWebNG.SRQLBehaviour

  def query(query, opts \\ %{}) when is_binary(query) do
    query_request(%{
      "query" => query,
      "limit" => Map.get(opts, :limit),
      "cursor" => Map.get(opts, :cursor),
      "direction" => Map.get(opts, :direction),
      "mode" => Map.get(opts, :mode),
      "scope" => Map.get(opts, :scope)
    })
  end

  def query_request(%{} = request) do
    case normalize_request(request) do
      {:ok, query, limit, cursor, direction, mode, scope} ->
        # Check if we should route through Ash adapter
        entity = extract_entity(query)

        if ash_srql_enabled?() and AshAdapter.ash_entity?(entity) do
          execute_ash_query(entity, query, limit, cursor, scope)
        else
          execute_sql_query(query, limit, cursor, direction, mode)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Execute query through Ash adapter for supported entities
  # No SQL fallback - all entities MUST go through Ash
  defp execute_ash_query(entity, query, limit, cursor, scope) do
    params = parse_srql_params(query, limit, cursor)
    start_time = System.monotonic_time()

    case AshAdapter.query(entity, params, scope) do
      {:ok, response} ->
        emit_telemetry(:ash, entity, start_time, :ok)
        {:ok, response}

      {:error, reason} ->
        emit_telemetry(:ash, entity, start_time, :error)
        Logger.error("SRQL AshAdapter failed for #{entity}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # Execute query through traditional SQL path
  defp execute_sql_query(query, limit, cursor, direction, mode) do
    entity = extract_entity(query)
    start_time = System.monotonic_time()

    result =
      with {:ok, translation} <- translate(query, limit, cursor, direction, mode) do
        execute_translation(translation)
      end

    status = if match?({:ok, _}, result), do: :ok, else: :error
    emit_telemetry(:sql, entity, start_time, status)

    result
  end

  # Emit telemetry for SRQL query execution
  defp emit_telemetry(path, entity, start_time, status) do
    duration = System.monotonic_time() - start_time

    :telemetry.execute(
      [:serviceradar, :srql, :query],
      %{duration: duration},
      %{path: path, entity: entity, status: status}
    )
  end

  # Check if Ash SRQL adapter is enabled via feature flag
  defp ash_srql_enabled? do
    flags = Application.get_env(:serviceradar_web_ng, :feature_flags, [])
    Keyword.get(flags, :ash_srql_adapter, false)
  end

  # Extract entity name from SRQL query
  # Handles formats like "in:events ..." or "events | ..."
  defp extract_entity(query) when is_binary(query) do
    query = String.trim(query)

    # Check for "in:entity" format first (most common)
    case Regex.run(~r/^in:(\S+)/, query) do
      [_, entity] ->
        String.downcase(entity)

      nil ->
        # Fall back to legacy format (first word before pipe or space)
        query
        |> String.split(~r/[\s|]/, parts: 2)
        |> List.first()
        |> String.downcase()
    end
  end

  defp extract_entity(_), do: nil

  # Parse SRQL query into params for Ash adapter using the Rust parser.
  # The Rust parser handles all parsing - no regex fallback.
  defp parse_srql_params(query, limit, cursor) do
    case Native.parse_ast(query) do
      {:ok, json} ->
        case Jason.decode(json) do
          {:ok, ast} ->
            convert_ast_to_params(ast, limit, cursor)

          {:error, reason} ->
            Logger.error("Failed to decode SRQL AST JSON: #{inspect(reason)}")
            %{filters: [], sort: nil, limit: limit || 100, stats: nil, cursor: cursor}
        end

      {:error, reason} ->
        Logger.error("Failed to parse SRQL query: #{inspect(reason)}")
        %{filters: [], sort: nil, limit: limit || 100, stats: nil, cursor: cursor}
    end
  end

  # Convert Rust AST to Ash adapter params format
  defp convert_ast_to_params(ast, limit, cursor) do
    filters = convert_ast_filters(ast["filters"] || [])
    time_filter = convert_ast_time_filter(ast["time_filter"])
    sort = convert_ast_order(ast["order"] || [])
    stats = convert_ast_stats(ast["stats"])

    all_filters = if time_filter, do: [time_filter | filters], else: filters

    %{
      filters: all_filters,
      sort: sort,
      limit: limit || ast["limit"] || 100,
      stats: stats,
      cursor: cursor
    }
  end

  # Convert AST filters to Ash adapter format
  defp convert_ast_filters(filters) when is_list(filters) do
    Enum.map(filters, fn filter ->
      %{
        field: filter["field"],
        op: convert_filter_op(filter["op"]),
        value: convert_filter_value(filter["value"])
      }
    end)
  end

  defp convert_ast_filters(_), do: []

  defp convert_filter_op("eq"), do: "eq"
  defp convert_filter_op("not_eq"), do: "neq"
  defp convert_filter_op("like"), do: "contains"
  defp convert_filter_op("not_like"), do: "neq"
  defp convert_filter_op("in"), do: "in"
  defp convert_filter_op("not_in"), do: "neq"
  defp convert_filter_op("gt"), do: "gt"
  defp convert_filter_op("gte"), do: "gte"
  defp convert_filter_op("lt"), do: "lt"
  defp convert_filter_op("lte"), do: "lte"
  defp convert_filter_op(op), do: op

  defp convert_filter_value(value) when is_list(value), do: value
  defp convert_filter_value(value), do: value

  # Convert AST time_filter to Ash adapter format
  defp convert_ast_time_filter(nil), do: nil

  defp convert_ast_time_filter(%{"type" => "relative_hours", "RelativeHours" => hours}) do
    %{field: "timestamp", op: "gte", value: ago(hours, :hour)}
  end

  defp convert_ast_time_filter(%{"type" => "relative_days", "RelativeDays" => days}) do
    %{field: "timestamp", op: "gte", value: ago(days, :day)}
  end

  defp convert_ast_time_filter(%{"type" => "today"}) do
    now = DateTime.utc_now()
    start_of_day = %{now | hour: 0, minute: 0, second: 0, microsecond: {0, 0}}
    %{field: "timestamp", op: "gte", value: start_of_day}
  end

  defp convert_ast_time_filter(%{"type" => "yesterday"}) do
    yesterday = DateTime.add(DateTime.utc_now(), -86_400, :second)
    start_of_day = %{yesterday | hour: 0, minute: 0, second: 0, microsecond: {0, 0}}
    %{field: "timestamp", op: "gte", value: start_of_day}
  end

  defp convert_ast_time_filter(%{"type" => "absolute", "start" => start_str, "end" => _end_str}) do
    case DateTime.from_iso8601(start_str) do
      {:ok, start, _} -> %{field: "timestamp", op: "gte", value: start}
      _ -> nil
    end
  end

  defp convert_ast_time_filter(_), do: nil

  # Convert AST order to Ash adapter format
  defp convert_ast_order([%{"field" => field, "direction" => dir} | _]) do
    %{field: field, dir: convert_sort_direction(dir)}
  end

  defp convert_ast_order(_), do: nil

  defp convert_sort_direction("asc"), do: "asc"
  defp convert_sort_direction("desc"), do: "desc"
  defp convert_sort_direction(_), do: "desc"

  # Convert AST stats to Ash adapter format
  defp convert_ast_stats(nil), do: nil

  defp convert_ast_stats(%{"aggregations" => aggregations}) when is_list(aggregations) do
    Enum.map(aggregations, fn agg ->
      %{
        type: String.to_atom(agg["type"] || "count"),
        field: agg["field"],
        alias: agg["alias"]
      }
    end)
    |> case do
      [] -> nil
      stats -> stats
    end
  end

  defp convert_ast_stats(_), do: nil

  defp ago(amount, :hour), do: DateTime.add(DateTime.utc_now(), -amount * 3600, :second)
  defp ago(amount, :day), do: DateTime.add(DateTime.utc_now(), -amount * 86_400, :second)

  defp translate(query, limit, cursor, direction, mode) do
    case Native.translate(query, limit, cursor, direction, mode) do
      {:ok, json} when is_binary(json) ->
        case Jason.decode(json) do
          {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}

      other ->
        {:error, {:unexpected_srql_translate_result, other}}
    end
  end

  defp execute_translation(%{"sql" => sql} = translation) when is_binary(sql) do
    params =
      translation
      |> Map.get("params", [])
      |> decode_params()

    with {:ok, params} <- params,
         {:ok, result} <- Ecto.Adapters.SQL.query(Repo, sql, params) do
      {:ok, build_response(translation, result)}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp execute_translation(_translation) do
    {:error, :invalid_srql_translation}
  end

  defp build_response(translation, %Postgrex.Result{columns: columns, rows: rows}) do
    results = build_results(columns, rows)
    viz = extract_viz(translation)
    pagination = build_pagination(translation, results)

    %{
      "results" => results,
      "pagination" => pagination,
      "viz" => viz,
      "error" => nil
    }
  end

  defp build_results([single], rows) when is_binary(single) do
    Enum.map(rows, fn
      [value] -> normalize_value(value)
      other -> normalize_value(other)
    end)
  end

  defp build_results(columns, rows) do
    Enum.map(rows, fn row ->
      columns
      |> Enum.zip(row)
      |> Map.new(fn {col, val} -> {col, normalize_value(val)} end)
      |> normalize_row_aliases()
    end)
  end

  defp extract_viz(translation) do
    case Map.get(translation, "viz") do
      value when is_map(value) -> value
      _ -> nil
    end
  end

  defp build_pagination(translation, results) do
    limit = pagination_limit(translation)

    %{
      "next_cursor" => next_cursor(translation, limit, results),
      "prev_cursor" => get_in(translation, ["pagination", "prev_cursor"]),
      "limit" => limit
    }
  end

  defp pagination_limit(translation) do
    case get_in(translation, ["pagination", "limit"]) do
      value when is_integer(value) -> value
      _ -> nil
    end
  end

  defp next_cursor(translation, limit, results) do
    candidate = get_in(translation, ["pagination", "next_cursor"])

    if is_integer(limit) and is_binary(candidate) and length(results) >= limit do
      candidate
    else
      nil
    end
  end

  defp normalize_row_aliases(row) when is_map(row) do
    row
    |> maybe_alias("device_id", "uid")
    |> maybe_alias("type", "device_type")
    |> maybe_alias("first_seen_time", "first_seen")
    |> maybe_alias("last_seen_time", "last_seen")
  end

  defp normalize_row_aliases(row), do: row

  defp maybe_alias(row, from, to) do
    cond do
      Map.has_key?(row, to) -> row
      Map.has_key?(row, from) -> Map.put(row, to, Map.get(row, from))
      true -> row
    end
  end

  defp normalize_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp normalize_value(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp normalize_value(%Date{} = value), do: Date.to_iso8601(value)
  defp normalize_value(%Time{} = value), do: Time.to_iso8601(value)
  defp normalize_value(%Decimal{} = value), do: Decimal.to_string(value)
  defp normalize_value(value), do: value

  defp decode_params(params) when is_list(params) do
    params
    |> Enum.reduce_while({:ok, []}, fn param, {:ok, acc} ->
      case decode_param(param) do
        {:ok, decoded} -> {:cont, {:ok, [decoded | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, decoded} -> {:ok, Enum.reverse(decoded)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode_params(_), do: {:error, :invalid_srql_params}

  defp decode_param(%{"t" => "text", "v" => value}) when is_binary(value), do: {:ok, value}
  defp decode_param(%{"t" => "bool", "v" => value}) when is_boolean(value), do: {:ok, value}
  defp decode_param(%{"t" => "int", "v" => value}) when is_integer(value), do: {:ok, value}

  defp decode_param(%{"t" => "int_array", "v" => values}) when is_list(values) do
    if Enum.all?(values, &is_integer/1) do
      {:ok, values}
    else
      {:error, :invalid_int_array_param}
    end
  end

  defp decode_param(%{"t" => "float", "v" => value}) when is_float(value), do: {:ok, value}
  defp decode_param(%{"t" => "float", "v" => value}) when is_integer(value), do: {:ok, value / 1}

  defp decode_param(%{"t" => "text_array", "v" => values}) when is_list(values) do
    if Enum.all?(values, &is_binary/1) do
      {:ok, values}
    else
      {:error, :invalid_text_array_param}
    end
  end

  defp decode_param(%{"t" => "timestamptz", "v" => value}) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> {:ok, datetime}
      _ -> {:error, :invalid_timestamptz_param}
    end
  end

  defp decode_param(_), do: {:error, :invalid_srql_param}

  defp normalize_request(%{"query" => query} = request) when is_binary(query) do
    limit = parse_limit(Map.get(request, "limit"))
    cursor = normalize_optional_string(Map.get(request, "cursor"))
    direction = normalize_direction(Map.get(request, "direction"))
    mode = normalize_optional_string(Map.get(request, "mode"))
    scope = Map.get(request, "scope")
    {:ok, query, limit, cursor, direction, mode, scope}
  end

  defp normalize_request(%{query: query} = request) when is_binary(query) do
    limit = parse_limit(Map.get(request, :limit))
    cursor = normalize_optional_string(Map.get(request, :cursor))
    direction = normalize_direction(Map.get(request, :direction))
    mode = normalize_optional_string(Map.get(request, :mode))
    scope = Map.get(request, :scope)
    {:ok, query, limit, cursor, direction, mode, scope}
  end

  defp normalize_request(_request) do
    {:error, "missing required field: query"}
  end

  defp parse_limit(nil), do: nil
  defp parse_limit(limit) when is_integer(limit), do: limit

  defp parse_limit(limit) when is_binary(limit) do
    case Integer.parse(limit) do
      {value, ""} -> value
      _ -> nil
    end
  end

  defp normalize_optional_string(nil), do: nil
  defp normalize_optional_string(""), do: nil
  defp normalize_optional_string(value) when is_binary(value), do: value
  defp normalize_optional_string(value), do: to_string(value)

  defp normalize_direction(nil), do: nil

  defp normalize_direction(direction) when direction in ["next", "prev"] do
    direction
  end

  defp normalize_direction(direction) when direction in [:next, :prev] do
    Atom.to_string(direction)
  end

  defp normalize_direction(_direction), do: nil
end
