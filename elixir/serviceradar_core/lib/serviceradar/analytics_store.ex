defmodule ServiceRadar.AnalyticsStore do
  @moduledoc """
  Write/query interface for high-volume telemetry.

  OpenSpec `add-analytics-store-drivers`. Operators pick `timescale`, `hybrid`, or
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
  alias ServiceRadar.AnalyticsStore.HybridWriter
  alias ServiceRadar.AnalyticsStore.PgDuckDBDriver
  alias ServiceRadar.AnalyticsStore.Query
  alias ServiceRadar.AnalyticsStore.TimescaleDriver

  @type table :: String.t()
  @type rows :: [map()]

  @doc "Persist `rows` to `table` via the table's configured driver."
  @spec write(table(), rows(), keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  def write(table, rows, opts \\ []) when is_binary(table) and is_list(rows) do
    cfg = Keyword.get_lazy(opts, :config, &Config.load/0)
    opts = Keyword.put(opts, :config, cfg)

    if Config.driver_for(cfg, table) == :hybrid do
      HybridWriter.write(table, rows, opts)
    else
      with {:ok, count} <- driver_mod(opts, table).write(table, rows, opts) do
        maybe_dual_write(cfg, table, rows, opts, count)
      end
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

    with {:ok, window} <- Query.query_window(opts) do
      cfg = Keyword.get_lazy(opts, :config, &Config.load/0)
      now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)

      case Config.read_driver_for(cfg, table, window, now) do
        :timescale -> TimescaleDriver.query(sql, params, opts)
        :pg_duckdb -> ServiceRadar.AnalyticsStore.SQL.query(table, sql, params, opts)
      end
    end
  end

  @doc "SQL dialect for `table` under the current (or supplied) config."
  @spec dialect(table(), keyword()) :: :postgres | :duckdb
  def dialect(table, opts \\ []) when is_binary(table) do
    cfg = Keyword.get_lazy(opts, :config, &Config.load/0)
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)

    window =
      case Query.query_window(opts) do
        {:ok, window} -> window
        {:error, _} -> {nil, nil}
      end

    case Config.read_driver_for(cfg, table, window, now) do
      :timescale -> :postgres
      :pg_duckdb -> :duckdb
    end
  end

  @doc """
  Table → read policy map for SRQL `translate`. Empty for Timescale-only reads,
  so postgres SQL stays byte-identical.
  """
  @spec driver_map(keyword()) :: %{String.t() => String.t() | map()}
  def driver_map(opts \\ []) do
    cfg = Keyword.get_lazy(opts, :config, &Config.load/0)

    cfg
    |> Config.analytics_tables()
    |> Enum.flat_map(fn entry ->
      case Config.driver_for(cfg, entry.table) do
        :pg_duckdb -> [{entry.table, "pg_duckdb"}]
        :hybrid -> [{entry.table, %{driver: "hybrid", hot_window_days: cfg.hot_window_days}}]
        :timescale -> []
      end
    end)
    |> Map.new()
  end

  defp driver_mod(opts, table) do
    cfg = Keyword.get_lazy(opts, :config, &Config.load/0)

    case Config.driver_for(cfg, table) do
      :timescale -> TimescaleDriver
      :pg_duckdb -> PgDuckDBDriver
    end
  end
end
