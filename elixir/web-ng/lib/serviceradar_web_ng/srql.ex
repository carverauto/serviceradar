defmodule ServiceRadarWebNG.SRQL do
  @moduledoc """
  SRQL (ServiceRadar Query Language) module.

  All queries are executed through the Rust NIF which generates parameterized SQL,
  then executed directly via Ecto adapters. No intermediate query layers.
  """

  @behaviour ServiceRadarWebNG.SRQLBehaviour

  alias ServiceRadar.Repo
  alias ServiceRadarWebNG.SRQL.Native

  require Logger

  Module.register_attribute(__MODULE__, :sobelow_skip, accumulate: true)

  def query(query, opts \\ %{}) when is_binary(query) do
    query_request(%{
      "query" => query,
      "limit" => Map.get(opts, :limit),
      "cursor" => Map.get(opts, :cursor),
      "direction" => Map.get(opts, :direction),
      "mode" => Map.get(opts, :mode)
    })
  end

  def query_request(%{} = request) do
    case normalize_request(request) do
      {:ok, query, limit, cursor, direction, mode} ->
        execute_query(query, limit, cursor, direction, mode)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp execute_query(query, limit, cursor, direction, mode) do
    entity = extract_entity(query)
    start_time = System.monotonic_time()

    result =
      with {:ok, translation} <- translate(query, limit, cursor, direction, mode) do
        execute_translation(Map.put(translation, "_query", query))
      end

    status = if match?({:ok, _}, result), do: :ok, else: :error
    emit_telemetry(entity, start_time, status)

    result
  end

  defp emit_telemetry(entity, start_time, status) do
    duration = System.monotonic_time() - start_time

    :telemetry.execute(
      [:serviceradar, :srql, :query],
      %{duration: duration},
      %{entity: entity, status: status}
    )
  end

  defp extract_entity(query) when is_binary(query) do
    query = String.trim(query)

    case Regex.run(~r/^in:(\S+)/, query) do
      [_, entity] ->
        String.downcase(entity)

      nil ->
        query
        |> String.split(~r/[\s|]/, parts: 2)
        |> List.first()
        |> String.downcase()
    end
  end

  defp extract_entity(_), do: nil

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
    translation
    |> Map.get("params", [])
    |> decode_params()
    |> case do
      {:ok, params} ->
        with {:ok, result} <- run_sql(sql, params) do
          {:ok, build_response(translation, result)}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp execute_translation(_translation) do
    {:error, :invalid_srql_translation}
  end

  @sobelow_skip ["SQL.Query"]
  defp run_sql(sql, params) do
    with :ok <- ensure_read_only_sql(sql) do
      Ecto.Adapters.SQL.query(Repo, sql, params)
    end
  end

  defp ensure_read_only_sql(sql) when is_binary(sql) do
    normalized =
      sql
      |> String.trim_leading()
      |> String.trim_trailing(";")

    cond do
      normalized == "" ->
        {:error, :empty_sql}

      String.contains?(normalized, ";") ->
        {:error, :multiple_sql_statements_not_allowed}

      Regex.match?(~r/\A(?:select|with)\b/i, normalized) ->
        :ok

      true ->
        {:error, :non_read_only_sql}
    end
  end

  defp build_response(translation, %Postgrex.Result{columns: columns, rows: rows}) do
    results =
      columns
      |> build_results(rows)
      |> enrich_downsample_aliases(translation)

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

  defp enrich_downsample_aliases(results, translation) when is_list(results) and is_map(translation) do
    query = Map.get(translation, "_query")
    series_field = extract_query_token(query, "series")

    value_field =
      extract_query_token(query, "value_field") || extract_query_token(query, "value-field")

    if is_nil(series_field) and is_nil(value_field) do
      results
    else
      Enum.map(results, fn
        %{} = row ->
          row
          |> maybe_alias("series", series_field)
          |> maybe_alias("value", value_field)

        other ->
          other
      end)
    end
  end

  defp enrich_downsample_aliases(results, _translation), do: results

  defp extract_query_token(query, key) when is_binary(query) and is_binary(key) do
    regex = ~r/(?:^|\s)#{Regex.escape(key)}:([^\s]+)/i

    case Regex.run(regex, query, capture: :all_but_first) do
      [value] ->
        value
        |> String.trim()
        |> String.trim("\"")
        |> case do
          "" -> nil
          v -> v
        end

      _ ->
        nil
    end
  end

  defp extract_query_token(_, _), do: nil

  defp normalize_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp normalize_value(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp normalize_value(%Date{} = value), do: Date.to_iso8601(value)
  defp normalize_value(%Time{} = value), do: Time.to_iso8601(value)
  defp normalize_value(%Decimal{} = value), do: Decimal.to_string(value)

  defp normalize_value(value) when is_binary(value) do
    if String.valid?(value) do
      value
    else
      case Ecto.UUID.load(value) do
        {:ok, uuid} -> uuid
        :error -> Base.encode16(value)
      end
    end
  end

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

  defp decode_param(%{"t" => "uuid", "v" => value}) when is_binary(value) do
    # UUID is passed as a string, but Postgrex expects 16-byte binary
    # Use Ecto.UUID.dump to convert string to binary format
    case Ecto.UUID.dump(value) do
      {:ok, binary_uuid} -> {:ok, binary_uuid}
      :error -> {:error, :invalid_uuid_param}
    end
  end

  defp decode_param(%{"t" => type, "v" => value}) when type in ["inet", "cidr"] and is_binary(value) do
    case ServiceRadar.Types.Cidr.dump_to_native(value, []) do
      {:ok, inet} -> {:ok, inet}
      _ -> {:error, :invalid_inet_param}
    end
  end

  defp decode_param(_), do: {:error, :invalid_srql_param}

  defp normalize_request(%{"query" => query} = request) when is_binary(query) do
    limit = parse_limit(Map.get(request, "limit"))
    cursor = normalize_optional_string(Map.get(request, "cursor"))
    direction = normalize_direction(Map.get(request, "direction"))
    mode = normalize_optional_string(Map.get(request, "mode"))
    {:ok, query, limit, cursor, direction, mode}
  end

  defp normalize_request(%{query: query} = request) when is_binary(query) do
    limit = parse_limit(Map.get(request, :limit))
    cursor = normalize_optional_string(Map.get(request, :cursor))
    direction = normalize_direction(Map.get(request, :direction))
    mode = normalize_optional_string(Map.get(request, :mode))
    {:ok, query, limit, cursor, direction, mode}
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
