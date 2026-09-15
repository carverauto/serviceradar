defmodule ServiceRadar.AnalyticsStore.Parity do
  @moduledoc """
  Cutover checks: listing cardinality and ≥6h stats on the same UTC window
  against both drivers. Compares counts and aggregates, never payloads.
  """

  alias ServiceRadar.AnalyticsStore.Layout
  alias ServiceRadar.AnalyticsStore.Storage
  alias ServiceRadar.ColdTier.Registry.Table

  @avg_epsilon 1.0e-6
  @avg_rel 1.0e-9

  @type stats :: %{
          row_count: non_neg_integer(),
          avg_value: float() | nil,
          series_count: non_neg_integer()
        }

  @doc "Closed-window stats SQL for one registry table."
  @spec stats_sql(:postgres | :duckdb, Table.t(), DateTime.t(), DateTime.t(), String.t() | nil) ::
          String.t()
  def stats_sql(:postgres, %Table{} = entry, %DateTime{} = start_at, %DateTime{} = stop_at, _glob) do
    time = q(entry.time_column)

    """
    SELECT count(*)::bigint AS row_count,
           avg(value)::float8 AS avg_value,
           count(DISTINCT #{q("series_key")})::bigint AS series_count
      FROM platform.#{q(entry.table)}
     WHERE #{time} >= TIMESTAMPTZ '#{iso(start_at)}'
       AND #{time} <  TIMESTAMPTZ '#{iso(stop_at)}'
    """
  end

  def stats_sql(:duckdb, %Table{} = entry, %DateTime{} = start_at, %DateTime{} = stop_at, glob)
      when is_binary(glob) do
    time = q(entry.time_column)

    """
    SELECT count(*)::bigint AS row_count,
           avg(value)::float8 AS avg_value,
           count(DISTINCT #{q("series_key")})::bigint AS series_count
      FROM read_parquet('#{esc(glob)}', hive_partitioning := true)
     WHERE #{time} >= TIMESTAMPTZ '#{iso(start_at)}'
       AND #{time} <  TIMESTAMPTZ '#{iso(stop_at)}'
    """
  end

  @doc "Published hive glob for a table on the configured backend."
  @spec parquet_glob(ServiceRadar.AnalyticsStore.Config.t(), String.t()) ::
          {:ok, String.t()} | {:error, term()}
  def parquet_glob(cfg, table) when is_binary(table) do
    Storage.copy_target(cfg, Layout.published_glob(table))
  end

  @doc "Compare two stats rows. Row counts and series counts must match exactly."
  @spec compare(stats(), stats()) :: :ok | {:error, {:parity_mismatch, map()}}
  def compare(left, right) when is_map(left) and is_map(right) do
    count_ok = left.row_count == right.row_count
    series_ok = left.series_count == right.series_count
    avg_ok = avg_close?(left.avg_value, right.avg_value)

    if count_ok and series_ok and avg_ok do
      :ok
    else
      {:error, {:parity_mismatch, %{timescale: left, pg_duckdb: right}}}
    end
  end

  defp avg_close?(nil, nil), do: true

  defp avg_close?(a, b) when is_number(a) and is_number(b) do
    abs(a - b) <= max(@avg_epsilon, @avg_rel * max(abs(a), abs(b)))
  end

  defp avg_close?(_, _), do: false

  defp iso(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp q(name), do: ~s("#{String.replace(name, "\"", "\"\"")}")
  defp esc(url), do: String.replace(url, "'", "''")
end
