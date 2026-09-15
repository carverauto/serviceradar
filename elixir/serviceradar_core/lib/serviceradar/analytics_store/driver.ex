defmodule ServiceRadar.AnalyticsStore.Driver do
  @moduledoc """
  Callbacks implemented by each analytics-store backend.

  OpenSpec `add-analytics-store-drivers`. Timescale writes CNPG hypertables;
  pg_duckdb writes hive-partitioned Parquet through the analytics head.
  """

  @type table :: String.t()
  @type rows :: [map()]
  @type sql :: String.t()
  @type params :: [term()]
  @type dialect :: :postgres | :duckdb

  @callback write(table(), rows(), keyword()) ::
              {:ok, non_neg_integer()} | {:error, term()}

  @callback query(sql(), params(), keyword()) :: {:ok, term()} | {:error, term()}

  @callback dialect() :: dialect()
end
