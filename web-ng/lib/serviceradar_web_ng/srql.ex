defmodule ServiceRadarWebNG.SRQL do
  @moduledoc false

  alias ServiceRadarWebNG.Repo
  alias ServiceRadarWebNG.SRQL.Native

  @behaviour ServiceRadarWebNG.SRQLBehaviour

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
    with {:ok, query, limit, cursor, direction, mode} <- normalize_request(request),
         {:ok, translation} <- translate(query, limit, cursor, direction, mode),
         {:ok, response} <- execute_translation(translation) do
      {:ok, response}
    else
      {:error, reason} -> {:error, reason}
    end
  end

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
    results =
      case columns do
        [single] when is_binary(single) ->
          Enum.map(rows, fn
            [value] -> normalize_value(value)
            other -> normalize_value(other)
          end)

        _ ->
          Enum.map(rows, fn row ->
            columns
            |> Enum.zip(row)
            |> Map.new(fn {col, val} -> {col, normalize_value(val)} end)
          end)
      end

    limit =
      translation
      |> get_in(["pagination", "limit"])
      |> case do
        value when is_integer(value) -> value
        _ -> nil
      end

    prev_cursor = get_in(translation, ["pagination", "prev_cursor"])
    next_cursor_candidate = get_in(translation, ["pagination", "next_cursor"])

    next_cursor =
      cond do
        is_integer(limit) and is_binary(next_cursor_candidate) and length(results) >= limit ->
          next_cursor_candidate

        true ->
          nil
      end

    %{
      "results" => results,
      "pagination" => %{
        "next_cursor" => next_cursor,
        "prev_cursor" => prev_cursor,
        "limit" => limit
      },
      "error" => nil
    }
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
