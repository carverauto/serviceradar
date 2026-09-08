defmodule ServiceRadarWebNG.StorageUsage do
  @moduledoc """
  Runtime-local storage-tier usage facts for the tiered telemetry offload
  gauges (OpenSpec add-tiered-telemetry-offload, design D10).

  Hot-tier facts (hypertable sizes, database size) are always available and
  degrade to `0` when a table is missing or TimescaleDB is not installed.
  Cold-tier facts come from the cold-tier manifest tables
  (`platform.cold_chunk_exports` / `platform.cold_tier_boundaries`) and
  degrade to `:absent` on deployments where the cold-tier migration has not
  run yet.
  """

  alias ServiceRadar.ColdTier.Registry, as: ColdRegistry
  alias ServiceRadarWebNG.Repo

  @type cold_table_stats :: %{
          table: String.t(),
          cold_rows: non_neg_integer(),
          cold_bytes: non_neg_integer(),
          oldest_available_seconds: number() | nil,
          held_chunks: non_neg_integer(),
          quarantined_chunks: non_neg_integer()
        }

  @doc "Cold-registry table names tracked by the storage gauges."
  @spec registry_table_names() :: [String.t()]
  def registry_table_names, do: ColdRegistry.table_names()

  @doc """
  `hypertable_detailed_size(total_bytes)` per cold-registry table.

  Tables that are missing or not hypertables report `0` so the always-on
  gauge series stays present.
  """
  @spec hot_bytes_by_table() :: %{optional(String.t()) => non_neg_integer()}
  def hot_bytes_by_table do
    tables = registry_table_names()
    zeros = Map.new(tables, &{&1, 0})

    case Repo.query(
           """
           SELECT ht.hypertable_name,
                  COALESCE(sum(s.total_bytes), 0)::bigint AS total_bytes
           FROM timescaledb_information.hypertables ht
           JOIN LATERAL hypertable_detailed_size(
             format('%I.%I', ht.hypertable_schema, ht.hypertable_name)::regclass
           ) s ON true
           WHERE ht.hypertable_schema = $1 AND ht.hypertable_name = ANY($2)
           GROUP BY ht.hypertable_name
           """,
           [ColdRegistry.schema(), tables]
         ) do
      {:ok, %{rows: rows}} ->
        Enum.reduce(rows, zeros, fn [table, bytes], acc ->
          Map.put(acc, table, normalize_bytes(bytes))
        end)

      {:error, _} ->
        zeros
    end
  rescue
    _ -> Map.new(registry_table_names(), &{&1, 0})
  end

  @doc """
  Trailing ingest rate in bytes/day per cold-registry table.

  Derived from the on-disk size of CLOSED chunks in a trailing window rather
  than from sampling `hypertable_detailed_size` over time: retention drops
  (and cold-tier offload) shrink a hypertable, so a size delta reads as
  negative ingest. Chunk sizes in a window that ends before `now()` only ever
  reflect data that arrived, which is the quantity the retention-horizon
  projection needs (design D5/D10).

  The newest (still-filling) chunk is excluded — its size understates the
  rate. Tables with no closed chunks in the window report `0`.
  """
  @spec ingest_bytes_per_day_by_table(pos_integer()) :: %{optional(String.t()) => number()}
  def ingest_bytes_per_day_by_table(window_days \\ 7) do
    tables = registry_table_names()
    zeros = Map.new(tables, &{&1, 0})

    case Repo.query(
           """
           WITH windowed AS (
             SELECT c.hypertable_name,
                    s.total_bytes,
                    c.range_start,
                    c.range_end
             FROM timescaledb_information.chunks c
             JOIN LATERAL chunks_detailed_size(
               format('%I.%I', c.hypertable_schema, c.hypertable_name)::regclass
             ) s ON s.chunk_name = c.chunk_name
                AND s.chunk_schema = c.chunk_schema
             WHERE c.hypertable_schema = $1
               AND c.hypertable_name = ANY($2)
               AND c.range_end <= now()
               AND c.range_start >= now() - ($3::int * INTERVAL '1 day')
           )
           SELECT hypertable_name,
                  (sum(total_bytes) / GREATEST(
                    EXTRACT(epoch FROM (max(range_end) - min(range_start))) / 86400.0,
                    1.0
                  ))::double precision AS bytes_per_day
           FROM windowed
           GROUP BY hypertable_name
           """,
           [ColdRegistry.schema(), tables, window_days]
         ) do
      {:ok, %{rows: rows}} ->
        Enum.reduce(rows, zeros, fn [table, rate], acc ->
          Map.put(acc, table, normalize_rate(rate))
        end)

      {:error, _} ->
        zeros
    end
  rescue
    _ -> Map.new(registry_table_names(), &{&1, 0})
  end

  @doc "Size of the current database in bytes (`pg_database_size`)."
  @spec database_bytes() :: non_neg_integer()
  def database_bytes do
    case Repo.query("SELECT pg_database_size(current_database())::bigint") do
      {:ok, %{rows: [[bytes]]}} -> normalize_bytes(bytes)
      _ -> 0
    end
  rescue
    _ -> 0
  end

  @doc """
  Per-table cold-tier manifest aggregates from `platform.cold_chunk_exports`.

  Returns `:absent` when the manifest table does not exist (cold-tier
  migration not applied); consumers should emit nothing in that case.
  """
  @spec cold_manifest_stats() :: [cold_table_stats()] | :absent
  def cold_manifest_stats do
    case Repo.query("""
         SELECT table_name,
                COALESCE(sum(row_count) FILTER (WHERE status = 'verified'), 0)::bigint AS cold_rows,
                COALESCE(sum(bytes) FILTER (WHERE status = 'verified'), 0)::bigint AS cold_bytes,
                extract(epoch FROM min(range_start) FILTER (WHERE status = 'verified'))::double precision
                  AS oldest_epoch,
                count(*) FILTER (WHERE status IN ('pending', 'exported'))::bigint AS held_chunks,
                count(*) FILTER (WHERE status = 'quarantined')::bigint AS quarantined_chunks
         FROM platform.cold_chunk_exports
         GROUP BY table_name
         """) do
      {:ok, %{rows: rows}} ->
        Enum.map(rows, fn [table, cold_rows, cold_bytes, oldest_epoch, held, quarantined] ->
          %{
            table: table,
            cold_rows: normalize_bytes(cold_rows),
            cold_bytes: normalize_bytes(cold_bytes),
            oldest_available_seconds: oldest_epoch,
            held_chunks: normalize_bytes(held),
            quarantined_chunks: normalize_bytes(quarantined)
          }
        end)

      {:error, error} ->
        if undefined_table?(error), do: :absent, else: []
    end
  rescue
    _ -> []
  end

  @doc """
  Seconds of lag between `now()` and each table's cold completeness frontier
  from `platform.cold_tier_boundaries`.

  Returns `:absent` when the boundaries table does not exist.
  """
  @spec frontier_lag_seconds() :: [{String.t(), number()}] | :absent
  def frontier_lag_seconds do
    case Repo.query("""
         SELECT table_name,
                extract(epoch FROM (now() - frontier))::double precision AS lag_seconds
         FROM platform.cold_tier_boundaries
         WHERE frontier IS NOT NULL
         """) do
      {:ok, %{rows: rows}} ->
        Enum.map(rows, fn [table, lag] -> {table, lag || 0} end)

      {:error, error} ->
        if undefined_table?(error), do: :absent, else: []
    end
  rescue
    _ -> []
  end

  defp undefined_table?(%Postgrex.Error{postgres: %{code: :undefined_table}}), do: true
  defp undefined_table?(_), do: false

  defp normalize_bytes(bytes) when is_integer(bytes), do: max(bytes, 0)
  defp normalize_bytes(_), do: 0

  defp normalize_rate(rate) when is_number(rate), do: max(rate, 0)

  defp normalize_rate(%Decimal{} = rate), do: rate |> Decimal.to_float() |> max(0)

  defp normalize_rate(_), do: 0
end
