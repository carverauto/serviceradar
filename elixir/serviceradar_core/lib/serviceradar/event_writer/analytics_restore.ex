defmodule ServiceRadar.EventWriter.AnalyticsRestore do
  @moduledoc """
  Bounded recovery of the hot metrics copy from verified analytics files.

  This restores records that previously passed through JetStream and EventWriter.
  It does not publish a second archive copy or replace normal ingestion. Callers
  supply an explicit, closed recovery interval after enabling ongoing hot writes.
  Every window verifies the restored primary keys before advancing; rerunning an
  interrupted interval is safe with the hypertable's conflict handling.
  """

  alias ServiceRadar.AnalyticsStore.Config
  alias ServiceRadar.AnalyticsStore.SQL
  alias ServiceRadar.AnalyticsStore.TimescaleDriver
  alias ServiceRadar.ColdTier.Registry
  alias ServiceRadar.Repo

  @table "timeseries_metrics"
  @max_rows 50_000
  @max_window_seconds 300
  @column_atoms ~w(timestamp gateway_id agent_id metric_name metric_type device_id value unit tags partition scale is_delta target_device_ip if_index metadata created_at series_key counter_width)a
  @allowed_columns Map.new(@column_atoms, &{Atom.to_string(&1), &1})

  @doc "Restore the half-open interval `[start_at, end_at)` into the hot copy."
  @spec run(DateTime.t(), DateTime.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(%DateTime{} = start_at, %DateTime{} = end_at, opts \\ []) do
    window_seconds = Keyword.get(opts, :window_seconds, 300)

    if DateTime.before?(start_at, end_at) and is_integer(window_seconds) and
         window_seconds > 0 and window_seconds <= @max_window_seconds do
      cfg = Keyword.get_lazy(opts, :config, &Config.load/0)
      opts = Keyword.put(opts, :config, %{cfg | driver: :pg_duckdb, tables: MapSet.new([@table])})

      restore_windows(start_at, end_at, window_seconds, opts, %{
        windows: 0,
        scanned: 0,
        inserted: 0,
        verified: 0
      })
    else
      {:error, :invalid_restore_interval}
    end
  end

  defp restore_windows(start_at, end_at, seconds, opts, totals) do
    stop_at =
      Enum.min_by(
        [DateTime.add(start_at, seconds, :second), end_at],
        &DateTime.to_unix(&1, :microsecond)
      )

    case restore_window(start_at, stop_at, opts) do
      {:ok, result} ->
        totals = Map.merge(totals, result, fn _key, previous, current -> previous + current end)
        Keyword.get(opts, :progress, fn _ -> :ok end).(%{through: stop_at, totals: totals})

        if DateTime.before?(stop_at, end_at) do
          restore_windows(stop_at, end_at, seconds, opts, totals)
        else
          {:ok, totals}
        end

      {:error, reason} ->
        {:error, %{from: start_at, to: stop_at, completed: totals, reason: reason}}
    end
  end

  defp restore_window(start_at, end_at, opts) do
    query = Keyword.get(opts, :read, &read_window/3)
    write = Keyword.get(opts, :write, &write_rows/2)
    verify = Keyword.get(opts, :verify, &verify_rows/2)

    with {:ok, result} <- query.(start_at, end_at, opts),
         {:ok, rows} <- decode_result(result, start_at, end_at),
         rows =
           Enum.uniq_by(
             rows,
             &{DateTime.to_unix(&1.timestamp, :microsecond), &1.gateway_id, &1.series_key}
           ),
         {:ok, inserted} <- write.(rows, opts),
         {:ok, count} <- verify.(rows, opts),
         :ok <- verified(count, length(rows)) do
      {:ok, %{windows: 1, scanned: length(result.rows), inserted: inserted, verified: count}}
    end
  rescue
    error -> {:error, {:restore_window_exception, error}}
  end

  defp bounded(values) when length(values) <= @max_rows, do: :ok
  defp bounded(_values), do: {:error, :restore_window_too_dense}

  defp verified(count, count), do: :ok
  defp verified(actual, expected), do: {:error, {:restore_verification_failed, expected, actual}}

  defp read_window(start_at, end_at, opts) do
    columns =
      Enum.map_join(Registry.fetch!(@table).columns, ", ", fn {name, _, _} -> ~s("#{name}") end)

    sql = """
    SELECT #{columns} FROM timeseries_metrics
    WHERE timestamp >= $1 AND timestamp < $2
    ORDER BY timestamp, gateway_id, series_key, created_at ASC NULLS LAST
    LIMIT #{@max_rows + 1}
    """

    SQL.query(@table, sql, [start_at, end_at], Keyword.put(opts, :time_range, {start_at, end_at}))
  end

  defp decode_result(%{columns: columns, rows: values}, start_at, end_at)
       when is_list(columns) and is_list(values) do
    with :ok <- bounded(values) do
      decode_rows(columns, values, start_at, end_at)
    end
  end

  defp decode_result(_result, _start_at, _end_at), do: {:error, :invalid_restore_result}

  defp decode_rows(columns, values, start_at, end_at) do
    allowed = @allowed_columns

    if Enum.sort(columns) == Enum.sort(Map.keys(allowed)) do
      values
      |> Enum.reduce_while({:ok, []}, fn values, {:ok, rows} ->
        case decode_row(columns, values, start_at, end_at) do
          {:ok, row} -> {:cont, {:ok, [row | rows]}}
          {:error, _} = error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, rows} -> {:ok, Enum.reverse(rows)}
        error -> error
      end
    else
      {:error, :unexpected_restore_columns}
    end
  end

  defp decode_row(columns, values, start_at, end_at)
       when is_list(values) and length(values) == length(columns) do
    row =
      columns
      |> Enum.zip(values)
      |> Map.new(fn {name, value} -> {Map.fetch!(@allowed_columns, name), value} end)

    with {:ok, tags} <- decode_json(row.tags),
         {:ok, metadata} <- decode_json(row.metadata),
         {:ok, row} <- normalize_identity(row, start_at, end_at) do
      {:ok, %{row | tags: tags, metadata: metadata}}
    end
  end

  defp decode_row(_columns, _values, _start_at, _end_at), do: {:error, :invalid_restore_row_width}

  defp decode_json(nil), do: {:ok, nil}
  defp decode_json(value) when is_map(value) or is_list(value), do: {:ok, value}

  defp decode_json(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, _} -> {:error, :invalid_restore_json}
    end
  end

  defp decode_json(_value), do: {:error, :invalid_restore_json}

  defp normalize_identity(
         %{timestamp: %DateTime{} = timestamp, gateway_id: gateway, series_key: key} = row,
         start_at,
         end_at
       )
       when is_binary(gateway) and is_binary(key) do
    if DateTime.compare(timestamp, start_at) != :lt and DateTime.before?(timestamp, end_at) do
      {:ok, %{row | timestamp: DateTime.shift_zone!(timestamp, "Etc/UTC")}}
    else
      {:error, :restore_timestamp_outside_window}
    end
  end

  defp normalize_identity(_row, _start_at, _end_at), do: {:error, :invalid_restore_identity}

  defp write_rows(rows, opts) do
    TimescaleDriver.write(@table, rows,
      repo: Keyword.get(opts, :repo, Repo),
      on_conflict: :nothing,
      returning: false
    )
  end

  defp verify_rows([], _opts), do: {:ok, 0}

  defp verify_rows(rows, opts) do
    repo = Keyword.get(opts, :repo, Repo)

    sql = """
    SELECT count(*) FROM timeseries_metrics t
    JOIN unnest($1::timestamptz[], $2::text[], $3::text[]) AS expected(timestamp, gateway_id, series_key)
      ON t.timestamp = expected.timestamp AND t.gateway_id = expected.gateway_id
      AND t.series_key = expected.series_key
    """

    params = [
      Enum.map(rows, & &1.timestamp),
      Enum.map(rows, & &1.gateway_id),
      Enum.map(rows, & &1.series_key)
    ]

    case repo.query(sql, params, timeout: 60_000, log: false) do
      {:ok, %{rows: [[count]]}} -> {:ok, count}
      {:error, _} = error -> error
    end
  end
end
