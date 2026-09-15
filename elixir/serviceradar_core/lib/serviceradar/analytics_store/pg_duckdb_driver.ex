defmodule ServiceRadar.AnalyticsStore.PgDuckDBDriver do
  @moduledoc """
  Analytics-store driver for hive-partitioned Parquet via the pg_duckdb head.

  Writes: staging COPY → verify → publish. Queries land in a later slice
  (SRQL duckdb dialect). Never falls back to Timescale.
  """

  @behaviour ServiceRadar.AnalyticsStore.Driver

  alias ServiceRadar.AnalyticsStore.Writer

  @impl true
  def write(table, rows, opts), do: Writer.write(table, rows, opts)

  @impl true
  def query(_sql, _params, _opts), do: {:error, :pg_duckdb_query_not_implemented}

  @impl true
  def dialect, do: :duckdb
end
