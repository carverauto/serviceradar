defmodule ServiceRadar.AnalyticsStore.Backfill do
  @moduledoc """
  One-shot copy of a registry table from the primary hypertable into hive
  Parquet. Does not flip EventWriter.

  Large tables are copied partition-by-partition with an explicit count
  check: parquet rows must equal the hypertable count for that UTC date
  or the run stops.
  """

  alias ServiceRadar.AnalyticsStore.Config
  alias ServiceRadar.AnalyticsStore.Layout
  alias ServiceRadar.AnalyticsStore.Storage
  alias ServiceRadar.ColdTier.Registry
  alias ServiceRadar.ColdTier.Registry.Table

  @writer_id "backfill"
  @fdw_server "analytics_primary"
  @fdw_schema "analytics_src"

  @doc "UTC date + row count SQL against the primary hypertable."
  @spec partition_count_sql(Table.t()) :: String.t()
  def partition_count_sql(%Table{table: table, time_column: time}) do
    """
    SELECT (#{quote_ident(time)} AT TIME ZONE 'UTC')::date AS partition_date,
           count(*)::bigint AS row_count
      FROM platform.#{quote_ident(table)}
     GROUP BY 1
     ORDER BY 1
    """
  end

  @doc "postgres_fdw setup SQL. Password is interpolated; callers must not log it."
  @spec ensure_fdw_sql(Table.t(), map()) :: String.t()
  def ensure_fdw_sql(%Table{} = entry, primary) when is_map(primary) do
    host = Map.fetch!(primary, :host)
    port = Map.get(primary, :port, 5432)
    database = Map.get(primary, :database, "serviceradar")
    username = Map.fetch!(primary, :username)
    password = Map.fetch!(primary, :password)

    cols =
      Enum.map_join(entry.columns, ",\n    ", fn {name, type, _} ->
        "#{quote_ident(name)} #{type}"
      end)

    """
    CREATE EXTENSION IF NOT EXISTS postgres_fdw;
    CREATE SCHEMA IF NOT EXISTS #{@fdw_schema};
    DROP USER MAPPING IF EXISTS FOR CURRENT_USER SERVER #{@fdw_server};
    DROP SERVER IF EXISTS #{@fdw_server} CASCADE;
    CREATE SERVER #{@fdw_server} FOREIGN DATA WRAPPER postgres_fdw
      OPTIONS (host '#{esc(host)}', port '#{port}', dbname '#{esc(database)}');
    CREATE USER MAPPING FOR CURRENT_USER SERVER #{@fdw_server}
      OPTIONS (user '#{esc(username)}', password '#{esc(password)}');
    DROP FOREIGN TABLE IF EXISTS #{@fdw_schema}.#{quote_ident(entry.table)};
    CREATE FOREIGN TABLE #{@fdw_schema}.#{quote_ident(entry.table)} (
    #{cols}
    ) SERVER #{@fdw_server}
      OPTIONS (schema_name 'platform', table_name '#{esc(entry.table)}');
    """
  end

  @doc "Staging COPY + verify + publish SQL for one UTC date."
  @spec copy_partition_sql(Config.t(), Table.t(), Date.t(), String.t(), String.t()) ::
          {:ok, String.t()} | {:error, term()}
  def copy_partition_sql(
        %Config{} = cfg,
        %Table{} = entry,
        %Date{} = date,
        staging_url,
        published_url
      )
      when is_binary(staging_url) and is_binary(published_url) do
    select = Registry.export_select_list(entry)
    time = quote_ident(entry.time_column)
    start = Date.to_iso8601(date) <> " 00:00:00+00"
    stop = date |> Date.add(1) |> Date.to_iso8601() |> Kernel.<>(" 00:00:00+00")

    sql = """
    COPY (
      SELECT #{select}
        FROM #{@fdw_schema}.#{quote_ident(entry.table)}
       WHERE #{time} >= TIMESTAMPTZ '#{start}'
         AND #{time} <  TIMESTAMPTZ '#{stop}'
    ) TO '#{esc(staging_url)}' (FORMAT parquet, COMPRESSION zstd);
    """

    _ = cfg
    {:ok, sql <> Storage.publish_sql(staging_url, published_url)}
  end

  @doc "Object keys for a backfill partition (idempotent per date)."
  @spec partition_keys(String.t(), Date.t()) :: Layout.keys()
  def partition_keys(table, %Date{} = date) when is_binary(table) do
    batch_id = Date.to_iso8601(date)
    Layout.keys(table, date, @writer_id, batch_id)
  end

  @doc """
  Object keys for a half-open UTC window inside one hive day.

  Used for the incomplete current day: copy `[start, stop)` after dual-write
  starts, so EventWriter batches and this prefix do not share a key.
  """
  @spec range_keys(String.t(), DateTime.t(), DateTime.t()) :: Layout.keys()
  def range_keys(table, %DateTime{} = start_at, %DateTime{} = stop_at) when is_binary(table) do
    date = DateTime.to_date(start_at)

    batch_id =
      "#{Date.to_iso8601(date)}-#{DateTime.to_unix(start_at)}-#{DateTime.to_unix(stop_at)}"

    Layout.keys(table, date, @writer_id, batch_id)
  end

  @doc "Staging COPY + verify + publish SQL for a half-open timestamptz window."
  @spec copy_range_sql(
          Config.t(),
          Table.t(),
          DateTime.t(),
          DateTime.t(),
          String.t(),
          String.t()
        ) :: {:ok, String.t()} | {:error, term()}
  def copy_range_sql(
        %Config{} = cfg,
        %Table{} = entry,
        %DateTime{} = start_at,
        %DateTime{} = stop_at,
        staging_url,
        published_url
      )
      when is_binary(staging_url) and is_binary(published_url) do
    if DateTime.before?(start_at, stop_at) do
      select = Registry.export_select_list(entry)
      time = quote_ident(entry.time_column)
      start = DateTime.to_iso8601(start_at)
      stop = DateTime.to_iso8601(stop_at)

      sql = """
      COPY (
        SELECT #{select}
          FROM #{@fdw_schema}.#{quote_ident(entry.table)}
         WHERE #{time} >= TIMESTAMPTZ '#{esc(start)}'
           AND #{time} <  TIMESTAMPTZ '#{esc(stop)}'
      ) TO '#{esc(staging_url)}' (FORMAT parquet, COMPRESSION zstd);
      """

      _ = cfg
      {:ok, sql <> Storage.publish_sql(staging_url, published_url)}
    else
      {:error, :empty_range}
    end
  end

  @doc """
  Copy `table` partition by partition.

  Inject `:partitions` (`[%{date: Date.t(), count: non_neg_integer()}]`) and
  `:copy` (`(entry, date, expected, staging, published, opts -> {:ok, count} | {:error, term()})`)
  in tests. A count mismatch is `{:error, {:count_mismatch, date, expected, got}}`.
  """
  @spec run(String.t(), keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  def run(table, opts \\ []) when is_binary(table) do
    cfg = Keyword.get_lazy(opts, :config, &Config.load/0)

    case Registry.fetch(table) do
      {:ok, entry} -> run_entry(cfg, entry, opts)
      :error -> {:error, {:unknown_analytics_table, table}}
    end
  end

  defp run_entry(cfg, entry, opts) do
    partitions = Keyword.get_lazy(opts, :partitions, fn -> [] end)
    copy = Keyword.get(opts, :copy, &missing_copy/6)

    Enum.reduce_while(partitions, {:ok, 0}, fn %{date: date, count: expected}, {:ok, acc} ->
      keys = partition_keys(entry.table, date)

      result =
        with {:ok, staging} <- Storage.copy_target(cfg, keys.staging_key),
             {:ok, published} <- Storage.copy_target(cfg, keys.published_key) do
          copy.(entry, date, expected, staging, published, opts)
        end

      case result do
        {:ok, ^expected} -> {:cont, {:ok, acc + expected}}
        {:ok, got} -> {:halt, {:error, {:count_mismatch, date, expected, got}}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp missing_copy(_entry, _date, _expected, _staging, _published, _opts) do
    {:error, :copy_callback_required}
  end

  defp quote_ident(name), do: ~s("#{String.replace(name, "\"", "\"\"")}")
  defp esc(value), do: String.replace(to_string(value), "'", "''")
end
