defmodule ServiceRadar.Observability.SRQLRunner do
  @moduledoc """
  Minimal SRQL executor for `serviceradar_core`.

  `serviceradar_core` uses the SRQL NIF to translate queries to SQL, then executes
  them directly via Ecto adapters.

  This module intentionally keeps the surface area small for background jobs.
  """

  alias ServiceRadar.Repo

  @type page :: %{
          rows: [map()],
          next_cursor: String.t() | nil
        }

  @spec query(String.t(), keyword()) :: {:ok, list()} | {:error, term()}
  def query(query, opts \\ []) when is_binary(query) do
    with {:ok, %{rows: rows}} <- query_page(query, opts) do
      {:ok, rows}
    end
  end

  @spec query_page(String.t(), keyword()) :: {:ok, page()} | {:error, term()}
  def query_page(query, opts \\ []) when is_binary(query) do
    limit = Keyword.get(opts, :limit)
    cursor = Keyword.get(opts, :cursor)
    direction = Keyword.get(opts, :direction)
    mode = Keyword.get(opts, :mode)

    with {:ok, translation} <- translate(query, limit, cursor, direction, mode, opts),
         {:ok, sql} <- fetch_sql(translation),
         {:ok, params} <- decode_params(Map.get(translation, "params", []), opts),
         {:ok, %Postgrex.Result{columns: columns, rows: rows} = result} <-
           run_sql(sql, params, opts) do
      {:ok, %{rows: rows_to_maps(columns, rows), next_cursor: next_cursor(translation, result)}}
    end
  end

  defp translate(query, limit, cursor, direction, mode, opts) do
    translate_fn = Keyword.get(opts, :translate_fn, &ServiceRadarSRQL.Native.translate/5)

    case translate_fn.(query, limit, cursor, direction, mode) do
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

  defp fetch_sql(%{"sql" => sql}) when is_binary(sql) and sql != "", do: {:ok, sql}
  defp fetch_sql(_), do: {:error, :invalid_srql_translation}

  defp rows_to_maps(columns, rows) when is_list(columns) and is_list(rows) do
    Enum.map(rows, fn row ->
      columns
      |> Enum.zip(row)
      |> Map.new()
    end)
  end

  defp decode_params(params, opts) when is_list(params) do
    params
    |> Enum.reduce_while({:ok, []}, fn param, {:ok, acc} ->
      case decode_param(param, opts) do
        {:ok, decoded} -> {:cont, {:ok, [decoded | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, decoded} -> {:ok, Enum.reverse(decoded)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode_params(_, _opts), do: {:error, :invalid_srql_params}

  defp decode_param(%{"t" => "text", "v" => value}, opts) when is_binary(value) do
    text_param_decoder(opts).(value)
  end

  defp decode_param(%{"t" => "bool", "v" => value}, _opts) when is_boolean(value),
    do: {:ok, value}

  defp decode_param(%{"t" => "int", "v" => value}, _opts) when is_integer(value), do: {:ok, value}

  defp decode_param(%{"t" => "int_array", "v" => values}, _opts) when is_list(values) do
    if Enum.all?(values, &is_integer/1),
      do: {:ok, values},
      else: {:error, :invalid_int_array_param}
  end

  defp decode_param(%{"t" => "float", "v" => value}, _opts) when is_float(value), do: {:ok, value}

  defp decode_param(%{"t" => "float", "v" => value}, _opts) when is_integer(value),
    do: {:ok, value / 1}

  defp decode_param(%{"t" => "text_array", "v" => values}, _opts) when is_list(values) do
    if Enum.all?(values, &is_binary/1),
      do: {:ok, values},
      else: {:error, :invalid_text_array_param}
  end

  defp decode_param(%{"t" => "timestamptz", "v" => value}, _opts) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> {:ok, datetime}
      _ -> {:error, :invalid_timestamptz_param}
    end
  end

  defp decode_param(%{"t" => "uuid", "v" => value}, _opts) when is_binary(value) do
    case Ecto.UUID.dump(value) do
      {:ok, binary_uuid} -> {:ok, binary_uuid}
      :error -> {:error, :invalid_uuid_param}
    end
  end

  defp decode_param(%{"t" => type, "v" => value}, _opts)
       when type in ["inet", "cidr"] and is_binary(value) do
    case ServiceRadar.Types.Cidr.dump_to_native(value, []) do
      {:ok, inet} -> {:ok, inet}
      _ -> {:error, :invalid_inet_param}
    end
  end

  defp decode_param(_, _opts), do: {:error, :invalid_srql_param}

  defp run_sql(sql, params, opts) do
    query_fn = Keyword.get(opts, :query_fn, &default_query/2)
    query_fn.(sql, params)
  end

  defp default_query(sql, params), do: Ecto.Adapters.SQL.query(Repo, sql, params)

  defp next_cursor(translation, %Postgrex.Result{rows: rows}) do
    limit = get_in(translation, ["pagination", "limit"])
    candidate = get_in(translation, ["pagination", "next_cursor"])

    if is_integer(limit) and is_binary(candidate) and length(rows) >= limit do
      candidate
    else
      nil
    end
  end

  defp next_cursor(_translation, _result), do: nil

  defp text_param_decoder(opts) do
    Keyword.get(opts, :text_param_decoder, &default_text_param_decoder/1)
  end

  defp default_text_param_decoder(value), do: {:ok, value}
end
