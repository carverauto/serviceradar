defmodule ServiceRadar.Observability.SRQLRunner do
  @moduledoc """
  Minimal SRQL executor for `serviceradar_core`.

  `serviceradar_core` uses the SRQL NIF to translate queries to SQL, then executes
  them directly via Ecto adapters.

  This module intentionally keeps the surface area small for background jobs.
  """

  alias ServiceRadar.Analytics.StarRocks.CatalogAllowlist
  alias ServiceRadar.Analytics.StarRocks.EventDocuments
  alias ServiceRadar.Analytics.StarRocks.Query, as: StarRocksQuery
  alias ServiceRadar.Analytics.StarRocks.Readers
  alias ServiceRadar.Analytics.StarRocks.RollupFreshness
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

  @doc """
  Read current rates for at most 512 exact `{device_id, if_index}` pairs.

  Requires `:fresh_after` within the requested window (at most one hour).
  Each pair returns eight directional IF-MIB families. `status` distinguishes
  a measured rate, including zero, from unknown or ambiguous producers. Sample
  timestamps remain actual observations. This internal read expects its serving
  caller to authorize device and analytics access before returning the rows.
  """
  def interface_rates(pairs, since, until, opts \\ [])

  def interface_rates(pairs, %DateTime{} = since, %DateTime{} = until, opts)
      when is_list(pairs) do
    with {:ok, request} <- interface_rate_request(pairs, since, until, opts),
         {:ok, mode} <- backend_mode("in:snmp_metrics"),
         {:ok, json} <- ServiceRadarSRQL.Native.translate_interface_rates(request, mode),
         {:ok, translation} <- Jason.decode(json),
         {:ok, sql} <- fetch_sql(translation),
         :ok <- assert_executable(sql, mode),
         {:ok, params} <- decode_params(Map.get(translation, "params", []), opts),
         {:ok, %Postgrex.Result{columns: columns, rows: rows}} <- run_sql(sql, params, mode, opts) do
      if length(rows) == length(pairs) * 8,
        do: normalize_interface_rate_rows(rows_to_maps(columns, rows)),
        else: {:error, :incomplete_interface_rate_result}
    end
  end

  def interface_rates(_pairs, _since, _until, _opts),
    do: {:error, :invalid_interface_rate_request}

  defp normalize_interface_rate_rows(rows) do
    rows
    |> Enum.reduce_while({:ok, []}, fn row, {:ok, acc} ->
      with %{"observed_at" => observed, "previous_observed_at" => previous} <- row,
           {:ok, observed} <- rate_datetime(observed),
           {:ok, previous} <- rate_datetime(previous) do
        {:cont,
         {:ok, [%{row | "observed_at" => observed, "previous_observed_at" => previous} | acc]}}
      else
        _ -> {:halt, {:error, :invalid_interface_rate_timestamp}}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      error -> error
    end
  end

  defp rate_datetime(nil), do: {:ok, nil}
  defp rate_datetime(%DateTime{} = value), do: DateTime.shift_zone(value, "Etc/UTC")
  defp rate_datetime(%NaiveDateTime{} = value), do: DateTime.from_naive(value, "Etc/UTC")
  defp rate_datetime(_value), do: {:error, :invalid_interface_rate_timestamp}

  defp interface_rate_request(pairs, since, until, opts) do
    bounded = Enum.take(pairs, 513)

    with %DateTime{} = fresh_after <- Keyword.get(opts, :fresh_after),
         true <- bounded != [] and length(bounded) <= 512,
         true <-
           Enum.all?(bounded, fn
             {id, index} -> is_binary(id) and is_integer(index)
             _ -> false
           end),
         true <-
           Enum.reduce(bounded, 0, fn {id, _}, bytes -> bytes + byte_size(id) end) <= 1_048_576,
         {:ok, request} <-
           Jason.encode(%{
             pairs: Enum.map(bounded, fn {id, index} -> %{device_id: id, if_index: index} end),
             since: since,
             until: until,
             fresh_after: fresh_after
           }),
         true <- byte_size(request) <= 1_048_576 do
      {:ok, request}
    else
      _ -> {:error, :invalid_interface_rate_request}
    end
  end

  @spec query_page(String.t(), keyword()) :: {:ok, page()} | {:error, term()}
  def query_page(query, opts \\ []) when is_binary(query) do
    limit = Keyword.get(opts, :limit)
    cursor = Keyword.get(opts, :cursor)
    direction = Keyword.get(opts, :direction)

    with {:ok, mode} <- backend_mode(query),
         {:ok, translation} <- translate(query, limit, cursor, direction, mode, opts),
         {:ok, translation, mode} <-
           RollupFreshness.settle(
             translation,
             mode,
             &translate(query, limit, cursor, direction, &1, opts)
           ),
         {:ok, sql} <- fetch_sql(translation),
         :ok <- assert_executable(sql, mode),
         {:ok, params} <- decode_params(Map.get(translation, "params", []), opts),
         {:ok, %Postgrex.Result{columns: columns, rows: rows} = result} <-
           run_sql(sql, params, mode, opts) do
      {:ok,
       %{
         rows: columns |> rows_to_maps(rows) |> warehouse_shape(query, mode),
         next_cursor: next_cursor(translation, result)
       }}
    end
  end

  defp warehouse_shape(rows, query, mode) when mode in ["starrocks", "starrocks_raw"],
    do: EventDocuments.decode_rows(rows, Readers.entity_for_query(query))

  defp warehouse_shape(rows, _query, _mode), do: rows

  # Same two guards the web API applies before submitting compiled StarRocks
  # SQL: `RollupFreshness.settle/3` above, and a catalog reference refused
  # unless the JDBC catalog is actually provisioned.
  defp assert_executable(sql, mode) when mode in ["starrocks", "starrocks_raw"],
    do: CatalogAllowlist.assert_sql_executable(sql)

  defp assert_executable(_sql, _mode), do: :ok

  # Background jobs read from whichever backend owns the dataset, through the
  # same routing the web API uses. A dataset with no CNPG serving path answers
  # with its routing error here rather than quietly reading a table the
  # deployment may no longer write.
  defp backend_mode(query) do
    case query |> Readers.entity_for_query() |> Readers.mode_for() do
      {:error, _reason} = error -> error
      mode -> {:ok, mode}
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

  defp decode_param(%{"t" => "date", "v" => value}, _opts) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      _ -> {:error, :invalid_date_param}
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

  # 60s default: SRQL aggregations over TimescaleDB hypertables can be slow;
  # DBConnection's 15s default causes spurious disconnects under load.
  @default_query_timeout_ms 60_000

  defp run_sql(sql, params, mode, opts) do
    timeout = Keyword.get(opts, :timeout)
    query_fn = Keyword.get(opts, :query_fn, default_query_fn(mode, timeout))

    query_fn.(sql, params)
  end

  # StarRocks SQL is compiled with its literals inlined, which is why the
  # warehouse executor takes no parameters.
  defp default_query_fn(mode, timeout) when mode in ["starrocks", "starrocks_raw"] do
    # Preserve the warehouse client's own default, while forwarding an explicit
    # bounded-read timeout just as the PostgreSQL path does.
    opts = if is_nil(timeout), do: [], else: [timeout: timeout]
    fn sql, _params -> StarRocksQuery.execute(sql, opts) end
  end

  defp default_query_fn(_mode, timeout) do
    fn sql, params ->
      Ecto.Adapters.SQL.query(Repo, sql, params, timeout: timeout || @default_query_timeout_ms)
    end
  end

  defp next_cursor(translation, %Postgrex.Result{rows: rows}) do
    limit = get_in(translation, ["pagination", "limit"])
    candidate = get_in(translation, ["pagination", "next_cursor"])

    if is_integer(limit) and is_binary(candidate) and length(rows) >= limit do
      candidate
    end
  end

  defp text_param_decoder(opts) do
    Keyword.get(opts, :text_param_decoder, &default_text_param_decoder/1)
  end

  defp default_text_param_decoder(value), do: {:ok, value}
end
