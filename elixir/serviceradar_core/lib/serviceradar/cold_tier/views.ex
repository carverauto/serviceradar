defmodule ServiceRadar.ColdTier.Views do
  @moduledoc """
  Stitched hot∪cold view generation on the analytics head (OpenSpec
  add-tiered-telemetry-offload, task 4.6; design D3/D7).

  Per registry table the head gets a `platform.<table>` view shaped exactly
  like the primary's table, so SRQL's schema-unqualified SQL resolves against
  it unchanged (`search_path = platform, public`):

      SELECT <cols>, <time>::date AS _cold_partition_date
        FROM read_parquet('s3://…/<table>/**', hive_partitioning := true)
       WHERE <time> < B
      UNION ALL
      SELECT <cols>, <time>::date AS _cold_partition_date
        FROM fdw_primary.<table>
       WHERE <time> >= B

  Three things make this work, all verified in Phase-0:

    * `B` is the head-acknowledged query boundary, and the half-open split
      (`< B` / `>= B`) means every row comes from exactly one branch. The
      exporter only marks chunks drop-eligible at or below an acked `B`, so
      the boundary can never outrun what the head can see (design D3).
    * Both branches are type-aligned. Parquet carries the registry's
      canonical export casts (uuid/jsonb → text), so the Parquet branch casts
      back to the primary's types where a DuckDB equivalent exists. `jsonb`
      is the documented exception — DuckDB has no jsonb, so those columns are
      text on both branches and JSON access is a dialect concern (D7/R7).
    * `_cold_partition_date` exposes the hive partition column. A `timestamp`
      predicate alone prunes row groups but never FILES; SRQL's cold dialect
      adds a redundant predicate on this column to prune partitions
      (spike 0.1c: 10 files read → 2).

  Views are generated from the registry, so a schema change flows through the
  registry (which the drift check enforces) into the views here.
  """

  alias ServiceRadar.ColdTier.Config
  alias ServiceRadar.ColdTier.Head
  alias ServiceRadar.ColdTier.Registry
  alias ServiceRadar.ColdTier.Registry.Table

  require Logger

  @partition_column "_cold_partition_date"
  @fdw_schema "fdw_primary"

  @doc "The infrastructure column exposing the hive partition for file pruning."
  @spec partition_column() :: String.t()
  def partition_column, do: @partition_column

  @doc """
  (Re)create every registry table's stitched view on the head using each
  table's currently acked boundary. Tables with no acked boundary are skipped
  — until the exporter has acked one there is no safe split point, and a view
  claiming otherwise could show gaps.
  """
  @spec ensure_all(pid(), %{optional(String.t()) => DateTime.t()}) :: :ok
  def ensure_all(conn, boundaries) do
    for entry <- Registry.tables() do
      case Map.get(boundaries, entry.table) do
        %DateTime{} = boundary -> ensure_view(conn, entry, boundary)
        _ -> Logger.debug("Cold tier: no acked boundary; skipping view", table: entry.table)
      end
    end

    :ok
  end

  @doc """
  (Re)create one stitched view for `entry` split at `boundary`.

  Drop-and-recreate rather than `CREATE OR REPLACE`: replacing a view cannot
  change its column list ("cannot change name of view column …"), and a
  registry/schema change legitimately does. PostgreSQL DDL is transactional,
  so wrapping both statements keeps the swap atomic — a concurrent reader
  either sees the old view or the new one, never a missing relation.
  """
  @spec ensure_view(pid(), Table.t(), DateTime.t()) :: :ok
  def ensure_view(conn, %Table{} = entry, %DateTime{} = boundary) do
    Head.query!(conn, "CREATE SCHEMA IF NOT EXISTS platform")

    Head.query!(conn, "BEGIN")

    try do
      Head.query!(conn, ~s(DROP VIEW IF EXISTS platform."#{entry.table}"))
      Head.query!(conn, view_sql(entry, boundary))
      Head.query!(conn, "COMMIT")
    rescue
      error ->
        Head.query!(conn, "ROLLBACK")
        reraise error, __STACKTRACE__
    end

    :ok
  end

  @doc """
  The `CREATE OR REPLACE VIEW` statement for one table. Pure — exposed for
  tests and for operators reproducing a view by hand.
  """
  @spec view_sql(Table.t(), DateTime.t()) :: String.t()
  def view_sql(%Table{} = entry, %DateTime{} = boundary) do
    {:ok, s3} = Config.s3()
    time = quoted(entry.time_column)
    bound = "TIMESTAMPTZ '#{DateTime.to_iso8601(boundary)}'"

    # Glob ONLY the published hive partitions (`date=...`). The exporter writes
    # to `_staging/` and copies onto the published key only after verification
    # (design D2; review F04), so a `**` glob here would expose in-flight and
    # failed exports — a COPY is non-preemptible and can leave a
    # complete-but-truncated object. Restricting the glob to `date=` is what
    # keeps "unverified objects are never readable" true for readers.
    glob = "#{s3.bucket_url}/cold/#{Registry.layout_version()}/#{entry.table}/date=*/*.parquet"

    cold_cols =
      Enum.map_join(entry.columns, ",\n         ", fn column ->
        "#{parquet_expression(column)} AS #{quoted(elem(column, 0))}"
      end)

    hot_cols =
      Enum.map_join(entry.columns, ",\n         ", fn column ->
        "#{fdw_expression(column)} AS #{quoted(elem(column, 0))}"
      end)

    """
    CREATE OR REPLACE VIEW platform.#{quoted(entry.table)} AS
      SELECT #{cold_cols},
             CAST(#{parquet_ref(entry.time_column)} AS DATE) AS #{quoted(@partition_column)}
        FROM read_parquet('#{glob}', hive_partitioning := true) r
       WHERE CAST(#{parquet_ref(entry.time_column)} AS TIMESTAMPTZ) < #{bound}
      UNION ALL
      SELECT #{hot_cols},
             CAST(#{time} AS DATE) AS #{quoted(@partition_column)}
        FROM #{@fdw_schema}.#{quoted(entry.table)}
       WHERE #{time} >= #{bound}
    """
  end

  # Parquet side: cast the canonical export representation back to the
  # primary's type so both branches union cleanly and consumers see the
  # shape they expect. jsonb stays text (DuckDB has no jsonb).
  defp parquet_expression({name, "uuid", :text}), do: "CAST(#{parquet_ref(name)} AS UUID)"
  defp parquet_expression({name, "jsonb", :text}), do: "CAST(#{parquet_ref(name)} AS VARCHAR)"

  defp parquet_expression({name, type, _cast}),
    do: "CAST(#{parquet_ref(name)} AS #{duckdb_type(type)})"

  # FDW side: only jsonb needs coercing, to meet the Parquet branch's text.
  defp fdw_expression({name, "jsonb", _cast}), do: "#{quoted(name)}::text"
  defp fdw_expression({name, _type, _cast}), do: quoted(name)

  defp parquet_ref(name), do: "r['#{name}']"

  # Type names must be spellable by BOTH engines: the view body is parsed by
  # PostgreSQL when the view is created, then executed by DuckDB. DuckDB's
  # `DOUBLE` is a shell type in PostgreSQL ("type \"double\" is only a shell"),
  # so float columns must use `float8`, which both accept (spike 0.2).
  defp duckdb_type("timestamptz"), do: "TIMESTAMPTZ"
  defp duckdb_type("text"), do: "VARCHAR"
  defp duckdb_type("integer"), do: "INTEGER"
  defp duckdb_type("bigint"), do: "BIGINT"
  defp duckdb_type("double precision"), do: "float8"
  defp duckdb_type("boolean"), do: "BOOLEAN"
  defp duckdb_type("uuid"), do: "UUID"
  defp duckdb_type("text[]"), do: "VARCHAR[]"

  defp quoted(name), do: ~s("#{name}")
end
