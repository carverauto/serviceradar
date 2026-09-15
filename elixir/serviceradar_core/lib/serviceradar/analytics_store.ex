defmodule ServiceRadar.AnalyticsStore do
  @moduledoc """
  Write/query interface for high-volume telemetry.

  OpenSpec `add-analytics-store-drivers`. Operators pick `timescale` or
  `pg_duckdb` in Helm/Compose; EventWriter, SRQL, and in-process readers
  go through this module.

  Reused in-tree pieces (do not reimplement):
  `ServiceRadar.ColdTier.Registry` (table inventory),
  `ServiceRadar.EventWriter.BulkInsert` (Timescale writes),
  `//docker/images:cnpg_analytics_image_amd64` (pg_duckdb head),
  Helm `coldTier.analyticsHead`, staging COPY helpers under
  `ServiceRadar.ColdTier`.
  """

  alias ServiceRadar.AnalyticsStore.Config
  alias ServiceRadar.AnalyticsStore.PgDuckDBDriver
  alias ServiceRadar.AnalyticsStore.TimescaleDriver

  @type table :: String.t()
  @type rows :: [map()]

  @doc "Persist `rows` to `table` via the table's configured driver."
  @spec write(table(), rows(), keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  def write(table, rows, opts \\ []) when is_binary(table) and is_list(rows) do
    cfg = Keyword.get_lazy(opts, :config, &Config.load/0)
    opts = Keyword.put(opts, :config, cfg)

    with {:ok, count} <- driver_mod(opts, table).write(table, rows, opts) do
      maybe_dual_write(cfg, table, rows, opts, count)
    end
  end

  defp maybe_dual_write(cfg, table, rows, opts, count) do
    if Config.dual_write?(cfg, table) and Config.driver_for(cfg, table) != :pg_duckdb do
      case PgDuckDBDriver.write(table, rows, opts) do
        {:ok, _} -> {:ok, count}
        {:error, reason} -> {:error, {:dual_write_failed, reason}}
      end
    else
      {:ok, count}
    end
  end

  @doc "Run parameterized SQL against the table's configured driver."
  @spec query(String.t(), [term()], keyword()) :: {:ok, term()} | {:error, term()}
  def query(sql, params, opts \\ []) when is_binary(sql) and is_list(params) do
    table = Keyword.get(opts, :table, "")
    driver_mod(opts, table).query(sql, params, opts)
  end

  @doc "SQL dialect for `table` under the current (or supplied) config."
  @spec dialect(table(), keyword()) :: :postgres | :duckdb
  def dialect(table, opts \\ []) when is_binary(table) do
    driver_mod(opts, table).dialect()
  end

  @doc """
  Table → driver map for SRQL `translate`. Empty when nothing is flipped,
  so postgres SQL stays byte-identical.
  """
  @spec driver_map(keyword()) :: %{String.t() => String.t()}
  def driver_map(opts \\ []) do
    cfg = Keyword.get_lazy(opts, :config, &Config.load/0)

    Map.new(Config.flipped_tables(cfg), fn entry ->
      {entry.table, "pg_duckdb"}
    end)
  end

  defp driver_mod(opts, table) do
    cfg = Keyword.get_lazy(opts, :config, &Config.load/0)

    case Config.driver_for(cfg, table) do
      :timescale -> TimescaleDriver
      :pg_duckdb -> PgDuckDBDriver
    end
  end
end
