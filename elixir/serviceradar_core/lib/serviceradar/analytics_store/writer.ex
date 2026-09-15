defmodule ServiceRadar.AnalyticsStore.Writer do
  @moduledoc """
  Staging COPY → verify → publish for one EventWriter batch.

  Head IO is injected (`:session`) so unit tests never need a live pg_duckdb.
  The default session is `ServiceRadar.AnalyticsStore.Head.session/2`.
  """

  alias ServiceRadar.AnalyticsStore.Config
  alias ServiceRadar.AnalyticsStore.Head
  alias ServiceRadar.AnalyticsStore.Layout
  alias ServiceRadar.AnalyticsStore.Storage
  alias ServiceRadar.ColdTier.Registry
  alias ServiceRadar.EventWriter.BulkInsert

  @writer_id "core-elx"

  @doc "Write `rows` for `table` through the pg_duckdb driver."
  @spec write(String.t(), [map()], keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  def write(_table, [], _opts), do: {:ok, 0}

  def write(table, rows, opts) when is_binary(table) and is_list(rows) do
    cfg = Keyword.get_lazy(opts, :config, &Config.load/0)

    case Registry.fetch(table) do
      {:ok, entry} ->
        write_grouped(cfg, entry, rows, opts)

      :error ->
        {:error, {:unknown_analytics_table, table}}
    end
  end

  defp write_grouped(cfg, entry, rows, opts) do
    {ok_rows, bad} =
      Enum.split_with(rows, fn row ->
        match?({:ok, _}, Layout.partition_date(row, entry.time_column))
      end)

    if bad != [] do
      {:error, {:rows_missing_timestamp, length(bad)}}
    else
      ok_rows
      |> Enum.group_by(fn row ->
        {:ok, date} = Layout.partition_date(row, entry.time_column)
        date
      end)
      |> Enum.reduce_while({:ok, 0}, fn {date, group}, {:ok, acc} ->
        case write_partition(cfg, entry, date, group, opts) do
          {:ok, count} -> {:cont, {:ok, acc + count}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
    end
  end

  defp write_partition(cfg, entry, %Date{} = date, rows, opts) do
    batch_id =
      opts
      |> Keyword.get_lazy(:batch_id, fn -> :erlang.unique_integer([:positive]) end)
      |> batch_id()
    writer = Keyword.get(opts, :writer_id, @writer_id)
    keys = Layout.keys(entry.table, date, writer, batch_id)

    with {:ok, staging_url} <- Storage.copy_target(cfg, keys.staging_key),
         {:ok, published_url} <- Storage.copy_target(cfg, keys.published_key),
         {:ok, written} <- run_head(cfg, opts, fn conn ->
           copy_and_verify(conn, entry, rows, staging_url, published_url, opts)
         end),
         :ok <- record_manifest(cfg, entry, keys, written, opts) do
      {:ok, written}
    end
  end

  defp copy_and_verify(conn, entry, rows, staging_url, published_url, opts) do
    query = Keyword.get(opts, :query, &query!/3)

    query.(conn, Head.create_temp_sql(entry), [])

    rows
    |> chunk_rows()
    |> Enum.each(fn chunk ->
      {sql, params} = Head.insert_sql(entry, chunk)
      query.(conn, sql, params)
    end)

    query.(conn, Head.copy_sql(entry, staging_url), [])

    verify = Keyword.get(opts, :verify, &verify_count/3)

    case verify.(conn, entry, staging_url) do
      {:ok, count} when count == length(rows) ->
        query.(conn, Storage.publish_sql(staging_url, published_url), [])
        count

      {:ok, count} ->
        raise "parquet verify count #{count} != #{length(rows)}"

      {:error, reason} ->
        raise "parquet verify failed: #{inspect(reason)}"
    end
  end

  defp verify_count(conn, entry, url) do
    %Postgrex.Result{rows: [[count | _]]} =
      query!(conn, Head.verify_sql(entry, url), [])

    {:ok, count}
  end

  defp run_head(cfg, opts, fun) do
    session = Keyword.get(opts, :session, &Head.session/2)

    case session.(cfg, fun) do
      {:ok, count} when is_integer(count) -> {:ok, count}
      {:ok, other} -> {:error, {:unexpected_head_result, other}}
      {:error, reason} -> {:error, reason}
    end
  rescue
    exception -> {:error, exception}
  end

  defp record_manifest(_cfg, entry, keys, count, opts) do
    attrs = %{
      table_name: entry.table,
      object_key: keys.published_key,
      staging_key: keys.staging_key,
      partition_date: keys.partition_date,
      row_count: count,
      batch_id: keys.batch_id,
      status: :published
    }

    case Keyword.get(opts, :record_manifest) do
      fun when is_function(fun, 1) -> fun.(attrs)
      nil -> default_record(attrs)
    end
  end

  defp default_record(attrs) do
    ServiceRadar.AnalyticsStore.FileManifest.record(attrs)
  end

  defp chunk_rows(rows) do
    size = BulkInsert.max_rows_per_statement(rows)
    Enum.chunk_every(rows, size)
  end

  defp query!(conn, sql, params) do
    Postgrex.query!(conn, sql, params, timeout: :infinity)
  end

  defp batch_id(int) when is_integer(int), do: Integer.to_string(int)
  defp batch_id(id) when is_binary(id), do: id
end
