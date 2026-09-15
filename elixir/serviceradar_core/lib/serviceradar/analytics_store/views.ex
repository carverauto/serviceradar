defmodule ServiceRadar.AnalyticsStore.Views do
  @moduledoc """
  Registry-driven hive views on the analytics head.

  Each flipped table is `platform.<table>` over published Parquet only
  (`date=*/*.parquet`). Staging keys are never in the glob. There is no
  postgres_fdw / hot union — the head is the store, not a stitch.
  """

  alias ServiceRadar.AnalyticsStore.Config
  alias ServiceRadar.AnalyticsStore.Layout
  alias ServiceRadar.AnalyticsStore.Storage
  alias ServiceRadar.ColdTier.Registry.Table

  @partition_column "_partition_date"

  @doc "Hive partition column exposed on every view."
  @spec partition_column() :: String.t()
  def partition_column, do: @partition_column

  @doc "Create or replace views for every table flipped onto pg_duckdb."
  @spec ensure_all(pid(), Config.t(), keyword()) :: :ok
  def ensure_all(conn, %Config{} = cfg, opts \\ []) do
    query = Keyword.get(opts, :query, &query!/3)

    Enum.each(Config.flipped_tables(cfg), fn entry ->
      ensure_view(conn, cfg, entry, query)
    end)

    :ok
  end

  @doc """
  Drop-and-recreate one view. PostgreSQL cannot change a view's column list
  with CREATE OR REPLACE, and a registry change legitimately does.
  """
  @spec ensure_view(pid(), Config.t(), Table.t(), (pid(), String.t(), [term()] -> term())) :: :ok
  def ensure_view(conn, %Config{} = cfg, %Table{} = entry, query) do
    query.(conn, "CREATE SCHEMA IF NOT EXISTS platform", [])
    query.(conn, "BEGIN", [])

    try do
      query.(conn, ~s(DROP VIEW IF EXISTS platform."#{entry.table}"), [])
      query.(conn, view_sql(cfg, entry), [])
      query.(conn, "COMMIT", [])
    rescue
      error ->
        query.(conn, "ROLLBACK", [])
        reraise error, __STACKTRACE__
    end

    :ok
  end

  @doc "CREATE VIEW SQL for one registry table. Pure — used by tests."
  @spec view_sql(Config.t(), Table.t()) :: String.t()
  def view_sql(%Config{} = cfg, %Table{} = entry) do
    glob = parquet_glob(cfg, entry.table)

    cols =
      Enum.map_join(entry.columns, ",\n         ", fn column ->
        "#{parquet_expression(column)} AS #{quoted(elem(column, 0))}"
      end)

    """
    CREATE VIEW platform.#{quoted(entry.table)} AS
      SELECT #{cols},
             CAST(r['date'] AS DATE) AS #{quoted(@partition_column)}
        FROM read_parquet('#{escape(glob)}', hive_partitioning := true) r
    """
  end

  defp parquet_glob(%Config{} = cfg, table) do
    case Storage.copy_target(cfg, Layout.published_glob(table)) do
      {:ok, url} -> url
      {:error, reason} -> raise ArgumentError, "analytics view glob: #{inspect(reason)}"
    end
  end

  # Parquet side: cast the canonical export representation back so consumers
  # see the registry types. jsonb stays text (DuckDB has no jsonb).
  defp parquet_expression({name, "uuid", :text}), do: "CAST(#{parquet_ref(name)} AS UUID)"
  defp parquet_expression({name, "jsonb", :text}), do: "CAST(#{parquet_ref(name)} AS VARCHAR)"

  defp parquet_expression({name, type, _cast}),
    do: "CAST(#{parquet_ref(name)} AS #{duckdb_type(type)})"

  defp parquet_ref(name), do: "r['#{name}']"

  # Type names must be spellable by BOTH engines: the view body is parsed by
  # PostgreSQL when the view is created, then executed by DuckDB. DuckDB's
  # DOUBLE is a shell type in PostgreSQL, so float columns use float8.
  defp duckdb_type("timestamptz"), do: "TIMESTAMPTZ"
  defp duckdb_type("text"), do: "VARCHAR"
  defp duckdb_type("integer"), do: "INTEGER"
  defp duckdb_type("bigint"), do: "BIGINT"
  defp duckdb_type("double precision"), do: "float8"
  defp duckdb_type("boolean"), do: "BOOLEAN"
  defp duckdb_type("uuid"), do: "UUID"
  defp duckdb_type("text[]"), do: "VARCHAR[]"
  defp duckdb_type(other), do: other

  defp quoted(name), do: ~s("#{name}")
  defp escape(url), do: String.replace(url, "'", "''")

  defp query!(conn, sql, params) do
    Postgrex.query!(conn, sql, params, timeout: :infinity)
  end
end
